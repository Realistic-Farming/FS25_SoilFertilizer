-- MAINT-229-section_stamp_spec_test.lua
--
-- MAINTENANCE row 229: a boom section that is switched off does not stamp Soil's
-- coverage record (the green spray square, pass % and the overlap stamp), which
-- #475/#476 decided and RSF-836 kept as its invariant 1.
--
-- THE DEFECT THIS PINS (development b7da77d3): the stamp walks getBoomCellPositions,
-- one span from the min to the max of _collectBoomNodes. That collector adds every
-- in-pass work area's corners whatever its section's state (workAreaInPass is a
-- spray-type test only), and the span is one line, so a section switched off in the
-- middle of the boom lies inside it and a boom-wide work area holds a switched-off
-- edge section in it. Both were stamped as sprayed.
--
-- "Off" is Tyson's Option B (2026-10-06): the state a section had before Soil's own
-- per-tick section logic ran, as the section state preserver saves it. The player's
-- width, the engine and another mod (a section-control mod writing section.isActive
-- before the tick) count; Soil's own See & Spray, Smart Sensor, overlap and boundary
-- suppressions keep stamping as before.
--
-- THE ENTRY-POINT BAR: every row installs the REAL installSprayerAreaHook and then the
-- REAL installSectionStatePreserver, in production's order (HookManager.lua:614 and
-- :808), and drives Sprayer.onStartWorkAreaProcessing and onEndWorkAreaProcessing as
-- the game does, through the REAL getBoomCellPositions, cellsToStamp, markBoomCells
-- and getBoomLineEndpoints. The fixture supplies what the engine supplies and nothing
-- Soil derives: the nodes where the i3d puts them, each section's isActive as the
-- player, the engine's partial width or a section-control mod leaves it before the
-- tick, and the work areas with their #sectionIndex. No saved state, cell, stamp or
-- section ground is set by hand. Asserted: the cells markBoomCells stamps (its own
-- sessionCoverageCells), the points and boom line paintBoomStrip is given, and the
-- section states after the tick.
--
-- The world (machines, harness, measurements) is MAINT-229-section_boom_world.lua.
--
-- Geometry: lanes run along world +Z, so the boom's lateral axis is world X, and the
-- lane sits at x = 25, so the 10 m columns are lateral [-25,-15], [-15,-5], [-5,5],
-- [5,15] and [15,25].
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, tools/test/lua/MAINT-229-section_boom_world.lua

local TICKS = SBW.TICKS
local cpBoom, perSectionBoom, streumaster = SBW.cpBoom, SBW.perSectionBoom, SBW.streumaster
local centreBoom = SBW.centreBoom
local switchOff, engineSetSections, run = SBW.switchOff, SBW.engineSetSections, SBW.run
local columnsByRow, paintShape = SBW.columnsByRow, SBW.paintShape

-- ══════════════════════════════════════════════════════════
-- A: ONE WORK AREA ACROSS THE BOOM, SECTIONS SWITCHED OFF BEFORE THE TICK
-- ══════════════════════════════════════════════════════════
local fullPaintPts
do
    local v = cpBoom()
    local ss, _, rec = run(v)
    local cols, nRows, same = columnsByRow(ss)
    T.eq("A0 full width: every column the boom crosses is stamped, as before", cols, "0,1,2,3,4")
    T.ok("A0b on all five rows the lane crossed", nRows == 5 and same)
    local identical = #rec.stamp > 0
    for k, pts in ipairs(rec.stamp) do
        if pts ~= (rec.paint[k] and rec.paint[k].pts) then identical = false end
    end
    T.ok("A0c full width: the stamp is given the sweep array itself, nothing rebuilt", identical)
    fullPaintPts = paintShape(rec)
end
do
    local v = cpBoom()
    switchOff(v, { 3, 6, -3, -6 })                     -- the middle 12 m
    local ss = run(v)
    local cols, nRows, same = columnsByRow(ss)
    T.eq("A1 middle 12 m off: its column is not stamped; the columns either side still are", cols, "0,1,3,4")
    T.ok("A1b on every row", nRows == 5 and same)
end
do
    local v = cpBoom()
    switchOff(v, { 12, 15, 18 })                       -- the outer 9 m on the +X side
    local ss = run(v)
    local cols = columnsByRow(ss)
    T.eq("A2 outer 9 m off at one edge: the work area's corner does not stamp it", cols, "0,1,2,3")
end
do
    local v = cpBoom()
    switchOff(v, { 3, 6, -3, -6, 12, 15, 18 })
    local ss, _, rec = run(v)
    local cols = columnsByRow(ss)
    T.eq("A3 middle and edge off together", cols, "0,1,3")
    local nPts, span, same, n = paintShape(rec)
    T.ok("A4 the dose paint is untouched: every tick paints, with the full sweep and the 36 m line",
         n == TICKS and same and nPts == fullPaintPts and math.abs(span - 36) < 1e-9)
    T.eq("A5 the sections stay off after the tick (the preserver restores the saved off state)",
         tostring(v.spec_variableWorkWidth.sections[6].isActive), "false")
end

do
    local v = centreBoom()
    local ss = run(v)
    T.eq("A6 a boom with a centre section, full width", columnsByRow(ss), "0,1,2,3")
    local v2 = centreBoom()
    switchOff(v2, { 1.5, 4.5, -4.5, 7.5, -7.5 })        -- the centre section and the two inner a side
    local ss2 = run(v2)
    T.eq("A6b the centre section and its neighbours off: their column is not stamped", columnsByRow(ss2), "0,1,3")
    local v3 = centreBoom()
    switchOff(v3, { 4.5, -4.5, 7.5, -7.5 })             -- the centre section keeps spraying
    local ss3 = run(v3)
    T.eq("A6c the centre section on between switched-off neighbours: its column is still stamped",
         columnsByRow(ss3), "0,1,2,3")
end

-- ══════════════════════════════════════════════════════════
-- B: SOIL'S OWN PER-TICK SUPPRESSION STILL STAMPS (Option B)
-- ══════════════════════════════════════════════════════════
do
    local v = cpBoom()
    local ss = run(v, false, function(sprayer)
        for _, s in ipairs(sprayer.spec_variableWorkWidth.sections) do
            if s.lat == 3 or s.lat == 6 or s.lat == -3 or s.lat == -6 or s.lat >= 12 then s.isActive = false end
        end
    end)
    local cols = columnsByRow(ss)
    T.eq("B1 the same sections switched off by a Soil hook after the preserver's save: stamped as before",
         cols, "0,1,2,3,4")
    T.eq("B2 and the preserver restores them on after the tick",
         tostring(v.spec_variableWorkWidth.sections[6].isActive), "true")
end

-- ══════════════════════════════════════════════════════════
-- W: WORK AREAS TIED TO SECTIONS (#sectionIndex), THE ENGINE'S OWN PARTIAL WIDTH
-- ══════════════════════════════════════════════════════════
do
    local v = perSectionBoom()
    local ss = run(v)
    T.eq("W0 per-section work areas, full width: the columns the boom crosses", columnsByRow(ss), "1,2,3")
end
do
    local v = perSectionBoom()
    engineSetSections(v, 1, 1)                         -- the engine keeps only the inner 3 m a side
    local ss = run(v)
    T.eq("W1 the engine's partial width idles the outer work areas, and their corners do not stamp",
         columnsByRow(ss), "2")
end

do
    -- Each section's work area reaches 3 m past its own edges, into its neighbours. Where
    -- a sprayed section's work area reaches, the ground is sprayed, whatever an
    -- overlapping switched-off section covers.
    local v = perSectionBoom(3)
    engineSetSections(v, 1, 1)
    local ss = run(v)
    T.eq("W2 overlapping work areas: ground a sprayed section's work area reaches stays stamped",
         columnsByRow(ss), "1,2,3")
end

-- ══════════════════════════════════════════════════════════
-- S: A PASS WHOSE SPRAY TYPE DOES NOT USE SECTIONS IS NOT FILTERED (#1039)
-- ══════════════════════════════════════════════════════════
do
    local v = streumaster(false, "LIME")
    switchOff(v, { 7.5, -7.5 })
    local ss = run(v)
    T.eq("S1 lime on the Streumaster spreads from its own 15 m work area: a section state does not filter it",
         columnsByRow(ss), "1,2,3")
end

-- ══════════════════════════════════════════════════════════
-- M: THE MULTI-TANK REPLAY STAMPS BY THE SAME RULE
-- ══════════════════════════════════════════════════════════
do
    local v = streumaster(true)
    local ss, _, rec = run(v, true)
    T.eq("M0 Streumaster fertilizer, full width: the columns its 42 m crosses", columnsByRow(ss), "0,1,2,3,4")
    T.eq("M0b the primary and the replay both stamp every tick", #rec.stamp, 2 * TICKS)
end
do
    local v = streumaster(true)
    switchOff(v, { 7.5, -7.5 })
    local ss, _, rec = run(v, true)
    T.eq("M1 inner sections off: neither the primary nor the replay stamps their column", columnsByRow(ss), "0,1,3,4")
    T.eq("M1b both still stamp every tick", #rec.stamp, 2 * TICKS)
end

SBW.restore()
