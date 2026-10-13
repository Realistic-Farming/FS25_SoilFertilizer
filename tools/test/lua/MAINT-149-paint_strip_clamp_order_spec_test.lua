-- MAINT-149-paint_strip_clamp_order_spec_test.lua
--
-- MAINTENANCE row 149 (Bob's intake of 2026-09-26, FAST TRACK, design origin none).
-- SoilValueMaps:addPaintStrip ran its saturation clamp AFTER the add, the order #1025
-- removed from the two aimed-delta paths. The clamp then took the pixels the add had
-- just carried into its window: a dose of d raw on a pixel at RAW_MAX - 2d + 1 ..
-- RAW_MAX - d ended at RAW_MAX, up to d - 1 over; a negative strip took a pixel at
-- rawLow + |d| .. rawLow + 2|d| - 1 to rawLow. Every fertilizer and tillage strip (N,
-- P, K, OM; pH where the positional writer is absent) and the narrow-tool dot write
-- through it. The clamp now runs first; the windows are unchanged, and so is the
-- sub-step quantisation (rows 66 and 71, under Tyson's Design hold).
--
-- THE ENTRY-POINT BAR IS GROUPS P AND N. The store is a SoilValueMaps through its own
-- initialize over the SF-995 pixel engine model (64 px, one metre a pixel); the writes
-- enter through SoilFertilitySystem:vmLocalBump, the tillage and residue strip
-- (SoilFertilitySystem.lua:4511), on a partial system over that store, with no worked
-- line recorded so the strip is the implement's radius either side of the position
-- (the first-tick case). N's negative strip is the OM oxidation shape (:1362). Pixels
-- are written through the store's own setPolygonWhere. Group S calls addPaintStrip
-- itself for the one clause no production caller reaches: a layer with its own
-- rawFloor (no strip writes one).
--
-- NOT DRIVEN: the narrow-tool dot (SoilFertilitySystem.lua:6264-6279) calls the same
-- addPaintStrip on a 5 m square; the rows below pin that function's arithmetic, and the
-- dot adds none of its own to it.
--
--!load: tools/test/lua/SF-995-engine_model.lua, src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/utils/SoilContextInput.lua, src/OrganicCertification.lua, src/config/SettingsSchema.lua, src/maps/SoilValueMaps.lua, src/SoilFertilitySystem.lua

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

g_server = {}
g_currentMission = { time = 1000 }
local vm = SoilValueMaps.new()
vm:initialize("/save")
local sys = setmetatable({ valueMaps = vm }, { __index = SoilFertilitySystem })

local HALF = ENGINE.TERRAIN * 0.5
local RAW_MAX = SoilValueMaps.RAW_MAX
local function box(ix0, iz0, ix1, iz1)
    local x0, z0, x1, z1 = -HALF + ix0 + 0.1, -HALF + iz0 + 0.1, -HALF + ix1 + 0.9, -HALF + iz1 + 0.9
    return { { x = x0, z = z0 }, { x = x1, z = z0 }, { x = x1, z = z1 }, { x = x0, z = z1 } }
end
local function put(key, ix, iz, raw) return vm:setPolygonWhere(key, box(ix, iz, ix, iz), raw, 0, RAW_MAX) end
local function at(key, ix, iz) return vm:readRawAtWorld(key, -HALF + ix + 0.5, -HALF + iz + 0.5) end
local function def(key)
    for _, d in ipairs(SoilValueMaps.LAYER_DEFS) do if d.key == key then return d end end
end
local function upr(key) local d = def(key) return (d.maxVal - d.minVal) / SoilValueMaps.RAW_SPAN end

-- One tick of vmLocalBump over pixels ix 10..19 of row iz: no worked line, so the
-- strip is `radius` either side of the position (4.9 m, a 9.8 m line), seeded one
-- metre wide on the row's centres. The caller's delta is one zone cell's amount;
-- vmLocalBump spreads it over the strip's area. `raw` is the step wanted per pixel.
local STRIP_AREA_M2 = 9.8
local function bump(key, iz, raw)
    g_currentMission.time = g_currentMission.time + 16
    local scale = SoilConstants.ZONE.CELL_AREA_HA / (STRIP_AREA_M2 / 10000)
    local sign = raw < 0 and -1 or 1
    local perPixel = sign * (math.abs(raw) + 0.5) * upr(key)
    sys:vmLocalBump(-HALF + 15, -HALF + iz + 0.5, { [key] = perPixel / scale }, 4.9, nil)
end

T.eq("R0 [reached] the store initialized over the pixel model", tostring(vm.available), "true")

-- ══════════════════════════════════════════════════════════════════════════
-- P. A DOSE ADDS ITS STEP, AND ONLY WHAT CANNOT TAKE IT SATURATES
-- ══════════════════════════════════════════════════════════════════════════
group("P", function()
    local N = "nitrogen"
    put(N, 10, 10, 100)
    put(N, 11, 10, RAW_MAX - 40 + 1)   -- 216: the first pixel the old order over-shot
    put(N, 12, 10, 225)
    put(N, 13, 10, RAW_MAX - 20)       -- 235: exactly one dose from full
    put(N, 14, 10, 240)
    bump(N, 10, 20)
    T.eq("P1 a strip dose of 20 raw through vmLocalBump: 100 takes exactly 20, and 216 and 225 end at 236 and 245, not at the ceiling",
        at(N, 10, 10) .. "/" .. at(N, 11, 10) .. "/" .. at(N, 12, 10), "120/236/245")
    T.eq("P2 a pixel exactly one dose from full reaches 255, one within a dose of full saturates at 255, and bare ground in the strip stays 0",
        at(N, 13, 10) .. "/" .. at(N, 14, 10) .. "/" .. at(N, 15, 10), "255/255/0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. A NEGATIVE STRIP TAKES ITS STEP, AND ONLY WHAT CANNOT TAKE IT FLOORS
-- ══════════════════════════════════════════════════════════════════════════
group("N", function()
    local OM = "organicMatter"
    put(OM, 10, 20, 100)
    put(OM, 11, 20, 30)    -- rawLow + 2|d| - 1: the last pixel the old order floored
    put(OM, 12, 20, 20)
    put(OM, 13, 20, 16)    -- rawLow + |d|: exactly one step from the floor
    put(OM, 14, 20, 10)
    bump(OM, 20, -15)
    T.eq("N1 an oxidation strip of -15 raw (the OM shape of :1362): 30 and 20 end at 15 and 5, not at the floor, and 100 at 85",
        at(OM, 11, 20) .. "/" .. at(OM, 12, 20) .. "/" .. at(OM, 10, 20), "15/5/85")
    T.eq("N2 a pixel exactly one step from the floor reaches raw 1, one within a step of it parks at raw 1, and bare ground stays 0",
        at(OM, 13, 20) .. "/" .. at(OM, 14, 20) .. "/" .. at(OM, 15, 20), "1/1/0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE STORE'S OWN CONTRACT: A LAYER WITH ITS OWN FLOOR
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    local WP = "weedPressure"
    T.eq("S0 weedPressure carries its own floor, raw 16", tostring(def(WP).rawFloor), "16")
    put(WP, 10, 30, 30)
    put(WP, 11, 30, 20)
    put(WP, 12, 30, 5)
    local b = box(10, 30, 13, 30)
    vm:addPaintStrip(WP, b[1].x, b[1].z, b[2].x, b[2].z, b[4].x, b[4].z, -(10.5 * upr(WP)))
    T.eq("S1 a -10 step on a layer floored at 16: 30 ends at 20, 20 parks at 16 (not 10), and 5 below the floor is left as it is, as is bare ground",
        at(WP, 10, 30) .. "/" .. at(WP, 11, 30) .. "/" .. at(WP, 12, 30) .. "/" .. at(WP, 13, 30), "20/16/5/0")
end)
