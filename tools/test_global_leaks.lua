--[[
    Test script to demonstrate global variable leaks
    Run with: lua test_global_leaks.lua
]]

print("=== GLOBAL LEAK DEMONSTRATION ===\n")

-- Simulate the buggy pattern
function buggyRepairEvent(farmId, vehicleId, component, cost)
    component = component or "all"
    cost = cost or 0  -- BUG: Creates global!

    print(string.format("  Repair: farmId=%d, cost=%d", farmId, cost))
    return cost
end

-- Simulate the fixed pattern
function fixedRepairEvent(farmId, vehicleId, component, cost)
    local component = component or "all"
    local cost = cost or 0  -- Safe: Local

    print(string.format("  Repair: farmId=%d, cost=%d", farmId, cost))
    return cost
end

print("--- BUGGY VERSION ---")
print("Call 1: cost=5000")
buggyRepairEvent(1, 123, "engine", 5000)
print(string.format("Global 'cost' after call 1: %s\n", tostring(cost)))

print("Call 2: cost=nil (should default to 0)")
buggyRepairEvent(2, 456, "engine", nil)
print(string.format("Global 'cost' after call 2: %s\n", tostring(cost)))

print("Call 3: cost=0 explicitly")
buggyRepairEvent(3, 789, "engine", 0)
print(string.format("Global 'cost' after call 3: %s\n", tostring(cost)))

-- Reset global
cost = nil

print("\n--- FIXED VERSION ---")
print("Call 1: cost=5000")
fixedRepairEvent(1, 123, "engine", 5000)
print(string.format("Global 'cost' after call 1: %s\n", tostring(cost)))

print("Call 2: cost=nil (should default to 0)")
fixedRepairEvent(2, 456, "engine", nil)
print(string.format("Global 'cost' after call 2: %s\n", tostring(cost)))

print("Call 3: cost=0 explicitly")
fixedRepairEvent(3, 789, "engine", 0)
print(string.format("Global 'cost' after call 3: %s\n", tostring(cost)))

print("\n=== EXPECTED OUTPUT ===")
print("Buggy version: Global 'cost' should leak (5000, then 0)")
print("Fixed version: Global 'cost' should stay nil")

print("\n=== MULTIPLAYER SCENARIO ===")
print("If two clients call buggyRepairEvent() with different costs,")
print("the global 'cost' will persist between calls, causing:")
print("  1. Client A charges $5000 (correct)")
print("  2. Client B charges $5000 (WRONG - should be $0)")
print("  3. Money mysteriously disappears!")
