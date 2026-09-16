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

T.summary()
