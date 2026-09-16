-- RSF-F226-workarea_wrap_slot_spec_test.lua
--
-- The work-area wrap slot. A processing function reaches the engine through THREE
-- copies in series and only the last one is ever called, so a wrapper installed on
-- either of the first two is inert. This bar exists because that exact mistake
-- shipped: the tedder hook reported a non-zero "patched" count for months while
-- its wrapper never executed once, and HayBet drying never fired.
--
-- The whole point is therefore to model the CHAIN rather than call the helper and
-- check a flag. Each case below builds a vehicle the way the engine does,
--   class table  ->  instance copy (Vehicle.lua:486)  ->  workArea capture
--   (WorkArea.lua:266)
-- and then dispatches the way the engine does,
--   workArea.processingFunction(vehicleSelf, workArea, dt)   (WorkArea.lua:182-183)
-- so "did the wrapper run" is answered by the same path the game uses. A test that
-- asserted the helper had assigned something would have passed against the broken
-- build too.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua

-- ── The engine's three-copy chain, modelled ──────────────────────────────────

--- Build a vehicle the way the engine builds one.
--- `areas` is a list of { functionName, fn }.
local function buildVehicle(specField, areas)
    local classTable = {}
    local vehicle = { [specField] = {}, spec_workArea = { workAreas = {} } }

    for _, a in ipairs(areas) do
        -- 1. the class/type function
        classTable[a.functionName] = a.fn
        -- 2. copyTypeFunctionsInto: the INSTANCE copy, before any onLoad
        vehicle[a.functionName] = classTable[a.functionName]
    end
    for _, a in ipairs(areas) do
        -- 3. WorkArea:onLoad captures from the instance copy
        local workArea = { functionName = a.functionName }
        workArea.processingFunction = vehicle[a.functionName]
        table.insert(vehicle.spec_workArea.workAreas, workArea)
    end
    return vehicle, classTable
end

--- Dispatch exactly as WorkArea.lua:182-183 does.
local function engineCall(vehicle, index, dt)
    local workArea = vehicle.spec_workArea.workAreas[index]
    local xs, second = workArea.processingFunction(vehicle, workArea, dt or 16)
    return xs, second
end

local W = HookManager.wrapWorkAreaProcessing
local U = HookManager.unwrapWorkAreaProcessing

-- ── A: the wrapper is reached through the slot the engine calls ──────────────
do
    local ran, sawVehicle, sawDt = 0, nil, nil
    local realCalls = 0
    local real = function(_self, _wa, _dt) realCalls = realCalls + 1 return 7, "orig" end
    local vehicle = buildVehicle("spec_tedder", { { functionName = "processTedderArea", fn = real } })

    local wrapped = W(vehicle, "spec_tedder", "processTedderArea", function(realFn)
        return function(vehSelf, wa, dt)
            ran = ran + 1
            sawVehicle, sawDt = vehSelf, dt
            local r = { realFn(vehSelf, wa, dt) }
            return unpack(r)
        end
    end)
    T.eq("A1 one work area wrapped", wrapped, 1)

    local xs, second = engineCall(vehicle, 1, 33)
    T.eq("A2 THE WRAPPER RAN through the engine's own dispatch", ran, 1)
    T.eq("A3 the original still ran exactly once", realCalls, 1)
    T.eq("A4 the first return survives, which WorkArea compares against zero", xs, 7)
    T.eq("A5 the second return survives too", second, "orig")
    T.ok("A6 the vehicle arrives as an explicit first argument, not through a colon call",
         sawVehicle == vehicle)
    T.eq("A7 dt is passed through untouched", sawDt, 33)
end

-- ── B: THE DEFECT. Wrapping the instance copy is inert. ──────────────────────
-- This is RSF-F226 reproduced. It is the case that would have caught the shipped
-- bug, and it is why A2 is asserted through engineCall rather than by inspecting
-- what the helper assigned.
do
    local ran = 0
    local real = function() return 5 end
    local vehicle = buildVehicle("spec_tedder", { { functionName = "processTedderArea", fn = real } })

    -- The old install, exactly: assign the instance copy after onLoad captured it.
    vehicle.processTedderArea = function(vehSelf, wa, dt)
        ran = ran + 1
        return real(vehSelf, wa, dt)
    end

    local xs = engineCall(vehicle, 1)
    T.eq("B1 patching the instance copy does NOT reach the engine's pointer", ran, 0)
    T.eq("B2 the original runs and the wrapper is simply never consulted", xs, 5)

    -- And the repair, on the same vehicle, does reach it.
    W(vehicle, "spec_tedder", "processTedderArea", function(realFn)
        return function(vehSelf, wa, dt) ran = ran + 100 return realFn(vehSelf, wa, dt) end
    end)
    engineCall(vehicle, 1)
    T.eq("B3 wrapping the work-area slot DOES reach it", ran, 100)
end

-- ── C: selection. Spec and function name both matter. ────────────────────────
do
    local vehicle = buildVehicle("spec_tedder", { { functionName = "processTedderArea", fn = function() return 1 end } })
    T.eq("C1 a vehicle without the owning spec is not wrapped",
         W(vehicle, "spec_mower", "processTedderArea", function(f) return f end), 0)
    T.eq("C2 a function name that is not present is not wrapped",
         W(vehicle, "spec_tedder", "processMowerArea", function(f) return f end), 0)
    T.eq("C3 the matching pair is wrapped",
         W(vehicle, "spec_tedder", "processTedderArea", function(f) return f end), 1)
end

do
    -- THE NAME COLLISION. All three carrier specs register a function called
    -- processDropArea (Mower.lua:34, Tedder.lua:23, Windrower.lua:27), so a
    -- selector built on functionName alone would wrap a mower's drop area from a
    -- tedder install.
    local mower = buildVehicle("spec_mower", {
        { functionName = "processMowerArea", fn = function() return 1 end },
        { functionName = "processDropArea",  fn = function() return 2 end },
    })
    T.eq("C4 a tedder install does not touch a mower's identically named drop area",
         W(mower, "spec_tedder", "processDropArea", function(f) return f end), 0)
    T.eq("C5 the mower's own install does",
         W(mower, "spec_mower", "processDropArea", function(f) return f end), 1)
    T.eq("C6 and it wrapped the drop area, not the mower area",
         mower.spec_workArea.workAreas[1]._sfWraps, nil)
end

-- ── D: idempotency. A second sweep must not stack wrappers. ──────────────────
do
    local depth = 0
    local vehicle = buildVehicle("spec_tedder", { { functionName = "processTedderArea", fn = function() return 3 end } })
    local mk = function(realFn)
        return function(vehSelf, wa, dt) depth = depth + 1 return realFn(vehSelf, wa, dt) end
    end
    T.eq("D1 first install wraps", W(vehicle, "spec_tedder", "processTedderArea", mk), 1)
    T.eq("D2 second install wraps nothing", W(vehicle, "spec_tedder", "processTedderArea", mk), 0)
    T.eq("D3 third install wraps nothing either", W(vehicle, "spec_tedder", "processTedderArea", mk), 0)
    engineCall(vehicle, 1)
    T.eq("D4 so exactly one wrapper layer runs, not three", depth, 1)
end

-- ── E: multiple matching work areas on one vehicle ───────────────────────────
do
    local hits = 0
    local vehicle = buildVehicle("spec_tedder", {
        { functionName = "processTedderArea", fn = function() return 1 end },
        { functionName = "processTedderArea", fn = function() return 2 end },
        { functionName = "processDropArea",   fn = function() return 3 end },
    })
    T.eq("E1 every matching work area is wrapped, not just the first",
         W(vehicle, "spec_tedder", "processTedderArea", function(realFn)
             return function(v, w, d) hits = hits + 1 return realFn(v, w, d) end
         end), 2)
    engineCall(vehicle, 1)
    engineCall(vehicle, 2)
    local xs3 = engineCall(vehicle, 3)
    T.eq("E2 both wrapped areas run", hits, 2)
    T.eq("E3 the unmatched drop area is untouched and still returns its own value", xs3, 3)
end

-- ── F: teardown restores only what is still ours ─────────────────────────────
do
    local vehicle = buildVehicle("spec_tedder", { { functionName = "processTedderArea", fn = function() return 9 end } })
    local originals = {}
    W(vehicle, "spec_tedder", "processTedderArea", function(realFn)
        local w = function(v, a, d) return realFn(v, a, d) end
        originals[w] = realFn
        return w
    end)
    local restored, left = U(vehicle, "spec_tedder", "processTedderArea", originals)
    T.eq("F1 our own wrapper is restored", restored, 1)
    T.eq("F2 nothing was left in place", left, 0)
    T.eq("F3 the engine pointer is the original again", engineCall(vehicle, 1), 9)

    -- Someone else wraps us afterwards: restoring would delete THEIR hook.
    local vehicle2 = buildVehicle("spec_tedder", { { functionName = "processTedderArea", fn = function() return 9 end } })
    local originals2 = {}
    W(vehicle2, "spec_tedder", "processTedderArea", function(realFn)
        local w = function(v, a, d) return realFn(v, a, d) end
        originals2[w] = realFn
        return w
    end)
    local foreignRan = 0
    local ours = vehicle2.spec_workArea.workAreas[1].processingFunction
    vehicle2.spec_workArea.workAreas[1].processingFunction = function(v, a, d)
        foreignRan = foreignRan + 1
        return ours(v, a, d)
    end
    local r2, l2 = U(vehicle2, "spec_tedder", "processTedderArea", originals2)
    T.eq("F4 a pointer another mod has since wrapped is NOT restored", r2, 0)
    T.eq("F5 it is reported as left in place", l2, 1)
    engineCall(vehicle2, 1)
    T.eq("F6 and the other mod's hook still runs rather than being silently deleted", foreignRan, 1)
end

-- ── G: shapes that must not throw ────────────────────────────────────────────
do
    T.eq("G1 a nil vehicle wraps nothing", W(nil, "spec_tedder", "processTedderArea", function(f) return f end), 0)
    T.eq("G2 a vehicle with no work-area spec wraps nothing",
         W({ spec_tedder = {} }, "spec_tedder", "processTedderArea", function(f) return f end), 0)
    T.eq("G3 a work-area spec with no areas wraps nothing",
         W({ spec_tedder = {}, spec_workArea = {} }, "spec_tedder", "processTedderArea", function(f) return f end), 0)
    local v = buildVehicle("spec_tedder", { { functionName = "processTedderArea", fn = function() return 1 end } })
    T.eq("G4 a maker that returns a non-function wraps nothing",
         W(v, "spec_tedder", "processTedderArea", function() return nil end), 0)
    T.eq("G5 and the engine pointer is left working", engineCall(v, 1), 1)
end


-- ── H: THE SEQUENCE Bob found, and it is the one that stacks ─────────────────
-- Install, another mod wraps on top, teardown, install again. Nothing pinned the
-- interaction between teardown and the idempotency test, and the failure is not
-- an error: the wrapper simply runs TWICE per pass, so a drying delta applies at
-- double rate with a green bar behind it.
--
-- Not reachable today, because unwrapWorkAreaProcessing has no production caller
-- and nothing builds the originals map. That is exactly why it is pinned now,
-- before the mower and windrower observers or a hot-reload path wire teardown up.
do
    local applied = 0
    local vehicle = buildVehicle("spec_tedder", { { functionName = "processTedderArea", fn = function() return 4 end } })
    local originals = {}
    local mk = function(realFn)
        local w = function(v, a, d) applied = applied + 1 return realFn(v, a, d) end
        originals[w] = realFn
        return w
    end

    T.eq("H1 install wraps once", W(vehicle, "spec_tedder", "processTedderArea", mk), 1)

    -- Another mod wraps on top of ours.
    local ours = vehicle.spec_workArea.workAreas[1].processingFunction
    vehicle.spec_workArea.workAreas[1].processingFunction = function(v, a, d) return ours(v, a, d) end

    local restored, left = U(vehicle, "spec_tedder", "processTedderArea", originals)
    T.eq("H2 teardown correctly restores nothing", restored, 0)
    T.eq("H3 and reports ours as left in the chain", left, 1)

    -- The install sweep runs again, as it does on every load.
    T.eq("H4 a re-install must NOT wrap a second time over our own live wrapper",
         W(vehicle, "spec_tedder", "processTedderArea", mk), 0)

    applied = 0
    engineCall(vehicle, 1)
    T.eq("H5 so the delta applies exactly ONCE per pass, not twice", applied, 1)
end

-- ── I: the selector still requires a real pointer ────────────────────────────
-- WorkArea.lua:262-264 refuses to insert an area whose function does not resolve,
-- so every inserted area has one. But if a foreign mod nils a pointer later, we
-- must not CREATE one where the engine has none: WorkArea.lua:182 guards on
-- `processingFunction ~= nil`, and filling that slot would defeat the guard and
-- then throw on a nil realFn inside the wrapper.
do
    local vehicle = buildVehicle("spec_tedder", { { functionName = "processTedderArea", fn = function() return 1 end } })
    vehicle.spec_workArea.workAreas[1].processingFunction = nil
    -- The maker MUST behave like the real one: HookManager's makeWrapper returns a
    -- closure whether or not realFn is anything, so a stub that returns f (and
    -- therefore nil) would let the helper's own "is it a function" check pass this
    -- case for the wrong reason. It did, on the first attempt, and the mutation
    -- survived until the stub was made honest.
    local realisticMaker = function(realFn)
        return function(v, a, d) return realFn(v, a, d) end
    end
    T.eq("I1 a work area whose pointer was nilled is not wrapped",
         W(vehicle, "spec_tedder", "processTedderArea", realisticMaker), 0)
    T.eq("I2 and no pointer is invented where the engine had none",
         vehicle.spec_workArea.workAreas[1].processingFunction, nil)
end


-- ── J: the combine half of the same defect ───────────────────────────────────
-- processCombineSwathArea was installed the same wrong way as the tedder's, onto
-- the instance copy that WorkArea:onLoad had already read from, so straw birth
-- has never been recorded from a combine swath in a shipped game.
--
-- It reaches the engine through the same slot: processCombineSwathArea has ZERO
-- direct callers anywhere in the decompiled engine, exactly like
-- processTedderArea and processWindrowerArea, which is what confirms it is
-- invoked only via WorkArea.lua:182-183.
do
    local ran, sawVehicle = 0, nil
    -- The engine's own swath function returns TWO values (Combine.lua:734-739
    -- returns 0, 0 on its refusal paths), and the first is the dropped litres the
    -- wrapper reads to decide whether anything landed. Both must survive.
    local real = function(_self, _wa) return 42, 7 end
    local combine = buildVehicle("spec_combine",
        { { functionName = "processCombineSwathArea", fn = real } })

    local wrapped = W(combine, "spec_combine", "processCombineSwathArea", function(realFn)
        return function(vehSelf, wa, dt)
            ran = ran + 1
            sawVehicle = vehSelf
            local r = { realFn(vehSelf, wa, dt) }
            return unpack(r)
        end
    end)
    T.eq("J1 the combine's swath area is wrapped", wrapped, 1)

    local dropped, second = engineCall(combine, 1)
    T.eq("J2 THE WRAPPER RAN through the engine's own dispatch", ran, 1)
    T.eq("J3 the dropped-litres return survives, which the wrapper reads as evidence", dropped, 42)
    T.eq("J4 the second return survives too", second, 7)
    T.ok("J5 the combine arrives as an explicit first argument", sawVehicle == combine)
end

do
    -- THE DEFECT, reproduced. This is what shipped.
    local ran = 0
    local real = function() return 99 end
    local combine = buildVehicle("spec_combine",
        { { functionName = "processCombineSwathArea", fn = real } })

    combine.processCombineSwathArea = function(vehSelf, wa, dt)
        ran = ran + 1
        return real(vehSelf, wa, dt)
    end

    local dropped = engineCall(combine, 1)
    T.eq("J6 patching the instance copy does NOT reach the engine's pointer", ran, 0)
    T.eq("J7 the original runs and the wrapper is never consulted", dropped, 99)

    W(combine, "spec_combine", "processCombineSwathArea", function(realFn)
        return function(v, w, d) ran = ran + 100 return realFn(v, w, d) end
    end)
    engineCall(combine, 1)
    T.eq("J8 wrapping the work-area slot DOES reach it", ran, 100)
end

do
    -- THE TWO CARRIERS MUST NOT CROSS. A combine and a tedder can both be on the
    -- map, and the selector takes the owning spec as well as the name, so neither
    -- install can reach the other's areas.
    local tedder = buildVehicle("spec_tedder",
        { { functionName = "processTedderArea", fn = function() return 1 end } })
    local combine = buildVehicle("spec_combine",
        { { functionName = "processCombineSwathArea", fn = function() return 2 end } })

    T.eq("J9 the combine install does not touch a tedder",
         W(tedder, "spec_combine", "processCombineSwathArea", function(f) return f end), 0)
    T.eq("J10 the tedder install does not touch a combine",
         W(combine, "spec_tedder", "processTedderArea", function(f) return f end), 0)
    T.eq("J11 each reaches its own",
         W(combine, "spec_combine", "processCombineSwathArea", function(f) return f end)
         + W(tedder, "spec_tedder", "processTedderArea", function(f) return f end), 2)
end

do
    -- A combine carrying BOTH a swath area and a chopper area: only the swath one
    -- is ours. Selecting on the spec alone would take both.
    local hits = 0
    local combine = buildVehicle("spec_combine", {
        { functionName = "processCombineChopperArea", fn = function() return 5 end },
        { functionName = "processCombineSwathArea",   fn = function() return 6 end },
    })
    T.eq("J12 only the swath area is wrapped, not the chopper area",
         W(combine, "spec_combine", "processCombineSwathArea", function(realFn)
             return function(v, w, d) hits = hits + 1 return realFn(v, w, d) end
         end), 1)
    local chopper = engineCall(combine, 1)
    engineCall(combine, 2)
    T.eq("J13 the chopper area runs untouched and returns its own value", chopper, 5)
    T.eq("J14 and only the swath pass reached our wrapper", hits, 1)
end

-- ── K: the INSTALL SITE passes the right arguments ──────────────────────────
-- Everything above tests the helper with arguments written out in the test. That
-- proves the helper behaves; it proves nothing about what installCombineSwathHook
-- actually hands it. Swap "spec_combine" for "spec_tedder" at the call site, or
-- misspell the function name, and every case above still passes while no combine
-- in the game is ever wrapped.
--
-- This is the same gap Bob found on MD-16, where reset was correct and nothing
-- proved it was still called. The answer there was to call the real entry point,
-- and it is the answer here: run the REAL installer against a real work-area
-- chain and assert the right area came back wrapped.
do
    local realRan = 0
    local combine = buildVehicle("spec_combine", {
        { functionName = "processCombineChopperArea", fn = function() return 1 end },
        { functionName = "processCombineSwathArea",   fn = function() realRan = realRan + 1 return 0, 0 end },
    })

    -- What the installer genuinely reads at install time: the Combine global it
    -- guards on, and the vehicle system it sweeps. Those two are load-bearing.
    local savedCombine, savedMission = Combine, g_currentMission
    Combine = { processCombineSwathArea = function() return 0, 0 end }
    g_currentMission = { vehicleSystem = { vehicles = { combine } } }

    -- THE ARGUMENT BELOW IS INERT FOR THIS CASE, and saying so is the point.
    -- installCombineSwathHook is declared with a colon, so this table lands in the
    -- implicit self. The installer captures it (`local hookMgrRef = self`) but the
    -- only use is hookMgrRef:getFieldIdAtWorldPosition deep inside the wrapper,
    -- past the isServer and isArmed returns that this case never gets past. So the
    -- stub method is never read, by this test or by K's dispatch.
    --
    -- It is left in place rather than deleted because it documents the real
    -- dependency, but the risk is worth naming: if the installer ever starts using
    -- self AT INSTALL TIME, this test feeds a one-method table while production
    -- feeds the real HookManager, and the bar would stay green straight across
    -- that divergence. An earlier version of this comment claimed the stub was a
    -- collaborator the installer reaches, which was simply not true.
    local installed = HookManager.installCombineSwathHook({
        getFieldIdAtWorldPosition = function() return 1 end,
    })
    T.eq("K1 the real installer reports success", installed, true)

    local areas = combine.spec_workArea.workAreas
    T.ok("K2 THE INSTALLER WRAPPED THE SWATH AREA, so it passed the right spec and name",
         areas[2]._sfWraps ~= nil and areas[2]._sfWraps["processCombineSwathArea"] ~= nil)
    T.eq("K3 and it left the chopper area alone", areas[1]._sfWraps, nil)

    -- Dispatch the way the engine does and confirm the original still runs
    -- underneath the installed wrapper.
    engineCall(combine, 2)
    T.eq("K4 the original swath function still runs through the installed wrapper", realRan, 1)

    Combine, g_currentMission = savedCombine, savedMission
end

-- ── L: the sprayer block, the OTHER half of the wrap slot ────────────────────
-- The overlap-prevention hook does not install a permanent wrapper; it swaps the
-- pointer out for one processing window and puts it back. Same slot, different
-- lifetime, and it was assigning the instance copy too, so the tank block has
-- never taken effect on any save.
local B = HookManager.blockWorkAreaProcessing
local Ub = HookManager.unblockWorkAreaProcessing

do
    local realRan = 0
    local real = function() realRan = realRan + 1 return 250, 3 end
    local sprayer = buildVehicle("spec_sprayer",
        { { functionName = "processSprayerArea", fn = real } })

    -- Unblocked, the engine reaches the real function and litres are drawn.
    local drawn = engineCall(sprayer, 1)
    T.eq("L1 unblocked, the sprayer draws from the tank", drawn, 250)
    T.eq("L2 and the real function ran", realRan, 1)

    T.eq("L3 the block takes one work area",
         B(sprayer, "spec_sprayer", "processSprayerArea", function() return 0, 0 end), 1)

    realRan = 0
    local blockedDraw, second = engineCall(sprayer, 1)
    T.eq("L4 BLOCKED, the engine's own dispatch draws nothing", blockedDraw, 0)
    T.eq("L5 and returns the second value the engine's refusal path returns", second, 0)
    T.eq("L6 THE REAL FUNCTION NEVER RAN, which is the whole point", realRan, 0)

    T.eq("L7 the restore puts one work area back", Ub(sprayer, "spec_sprayer", "processSprayerArea"), 1)
    local after = engineCall(sprayer, 1)
    T.eq("L8 restored, the sprayer draws again", after, 250)
    T.eq("L9 and it is the ORIGINAL function, not a copy of it",
         sprayer.spec_workArea.workAreas[1].processingFunction == real, true)
end

do
    -- THE DEFECT, reproduced. This is what shipped and why the tank kept draining.
    local realRan = 0
    local real = function() realRan = realRan + 1 return 250, 3 end
    local sprayer = buildVehicle("spec_sprayer",
        { { functionName = "processSprayerArea", fn = real } })

    sprayer.processSprayerArea = function() return 0 end

    local drawn = engineCall(sprayer, 1)
    T.eq("L10 blocking the instance copy does NOT stop the draw", drawn, 250)
    T.eq("L11 the real function ran anyway, which is the tank emptying", realRan, 1)
end

do
    -- PRECISION FARMING. With PF installed, the pointer WorkArea captured is
    -- already PF's wrapper, because ExtendedSprayer registers processSprayerArea
    -- through registerOverwrittenFunction, which rewrites objectType.functions
    -- before the instance copy is taken. So the restore MUST put back whatever was
    -- there rather than any known value: restoring the base function, or nilling
    -- the field as the old code did, silently deletes PF for the session.
    local pfRan, baseRan = 0, 0
    local base = function() baseRan = baseRan + 1 return 100, 1 end
    local sprayer = buildVehicle("spec_sprayer",
        { { functionName = "processSprayerArea", fn = base } })

    -- PF's wrapper is what the work area ends up holding.
    local pfWrapper = function(v, w, d) pfRan = pfRan + 1 return base(v, w, d) end
    sprayer.spec_workArea.workAreas[1].processingFunction = pfWrapper

    B(sprayer, "spec_sprayer", "processSprayerArea", function() return 0, 0 end)
    engineCall(sprayer, 1)
    T.eq("L12 while blocked, PF's wrapper does not run either", pfRan, 0)

    Ub(sprayer, "spec_sprayer", "processSprayerArea")
    T.eq("L13 THE RESTORE PUTS PF'S WRAPPER BACK, not the base function",
         sprayer.spec_workArea.workAreas[1].processingFunction == pfWrapper, true)
    engineCall(sprayer, 1)
    T.eq("L14 so PF still runs after a block/restore cycle", pfRan, 1)
    T.eq("L15 and the base function still runs underneath it", baseRan, 1)
end

do
    -- Lifetime edges. The block and the restore are separate engine callbacks, so
    -- a frame where one does not run must not lose the original.
    local real = function() return 7 end
    local sprayer = buildVehicle("spec_sprayer",
        { { functionName = "processSprayerArea", fn = real } })
    local blocker = function() return 0, 0 end

    T.eq("L16 first block takes it", B(sprayer, "spec_sprayer", "processSprayerArea", blocker), 1)
    T.eq("L17 a second block does NOT overwrite the saved original",
         B(sprayer, "spec_sprayer", "processSprayerArea", function() return 0, 0 end), 0)
    Ub(sprayer, "spec_sprayer", "processSprayerArea")
    T.eq("L18 so the restore still returns the true original",
         sprayer.spec_workArea.workAreas[1].processingFunction == real, true)

    T.eq("L19 restoring an unblocked area is a no-op",
         Ub(sprayer, "spec_sprayer", "processSprayerArea"), 0)
    T.eq("L20 and leaves the pointer alone",
         sprayer.spec_workArea.workAreas[1].processingFunction == real, true)
end

do
    -- Selection, same rule as the permanent wrapper: spec and name together.
    local tedder = buildVehicle("spec_tedder",
        { { functionName = "processTedderArea", fn = function() return 1 end } })
    T.eq("L21 a sprayer block does not touch a tedder",
         B(tedder, "spec_sprayer", "processSprayerArea", function() return 0, 0 end), 0)

    local sprayer = buildVehicle("spec_sprayer", {
        { functionName = "processSprayerArea", fn = function() return 2 end },
        { functionName = "processDropArea",    fn = function() return 3 end },
    })
    T.eq("L22 and it takes only the sprayer area, not a same-vehicle drop area",
         B(sprayer, "spec_sprayer", "processSprayerArea", function() return 0, 0 end), 1)
    T.eq("L23 the drop area is untouched", engineCall(sprayer, 2), 3)
end
