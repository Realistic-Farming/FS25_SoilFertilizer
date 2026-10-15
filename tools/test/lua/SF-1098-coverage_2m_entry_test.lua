-- SF-1098-coverage_2m_entry_test.lua
--
-- #1098 items 2 and 3 (iSinterra): Pass % (field.sessionCoverageFraction) and daily
-- coverage (field.coverageFraction) counted a WHOLE 10 m cell (0.01 ha) for every 10 m
-- cell any boom sample point landed in (markBoomCells), so a 12 m boom read as 20-30 m
-- wide and Pass % read ~99% at about 40-60% real coverage. At sessionCoverageFraction
-- >= 0.99 overlap prevention switches every section off and marks the pass blocked
-- (HookManager.lua, the onStartWorkAreaProcessing prepend, coverageComplete = coverage
-- >= 0.99 / _sfOverlapBlockedPass), and a blocked pass is not billed or drawn from the
-- tank (RSF-F226e) and credits nothing. The 80% protection grants read the same
-- fraction.
--
-- THE FIX: markBoomCells no longer adds coverage area. markOverlapCells(fieldId, points,
-- stampVehicle, countArea) adds ZONE.OVERLAP_CELL_AREA_HA (0.0004 ha) per newly stamped
-- 2 m cell to sessionCoverageHa, and per new 2 m DAILY cell (field.dailyOverlapCells,
-- reset in _processOneDailyField) to coveredAreaHa, only when countArea is true.
-- HookManager:markOverlapRecord(soilSys, fieldId, vehicle, countArea) passes it through;
-- installSprayerAreaHook's three call sites pass sectioned==true, true (hasVWW) and false
-- (broadcast / dry spreader, where litres own coverage through trackSprayerCoverage).
-- getBoomOverlapPositions now falls back to the implement's working width
-- (_implWorkingWidth) across the frame's origin when it finds fewer than two boom nodes.
--
-- THE ENTRY-POINT BAR. Groups A, B, C(partly), E, F and G drive production's real
-- Sprayer.onStartWorkAreaProcessing / onEndWorkAreaProcessing, through the REAL
-- installSprayerOverlapGate, installSprayerAreaHook, installOverlapPreventionHook (or
-- installSectionControlHook) and installSectionStatePreserver, installed in production's
-- own order -- the same entry point and install order as MAINT-234-overlap_record_spec_test
-- and overlap_own_pass_grace_test. The world (SF-1098-coverage_2m_world.lua) generalises
-- MAINT-234-overlap_record_world.lua's fixture (same engine-transform model: local X right
-- of travel, local Z along it, no i3d/physics) onto a configurable boom, because that
-- world's Hardi Mega 1200L fixture is fixed at a 24 m boom and cannot drive an exact 12 m
-- boom, a broadcast spreader with no VariableWorkWidth, or a rig with fewer than two boom
-- nodes but a declared implement width -- the three shapes this bar needs.
--
-- WHAT IS A DIRECT CALL INSTEAD, AND WHY. Group D's "the 2 m record adds no area" half
-- (D1-D7) calls SoilFertilitySystem:markOverlapCells directly: driving the full sprayer
-- hook to its broadcast litre branch needs g_sprayTypeManager / SprayerRateManager
-- machinery this world does not model, and building it would risk an unrelated Lua error
-- in code this change never touches, for a claim that is markOverlapCells's own contract
-- and is fully exercised by a direct call (the same kind of direct call
-- MAINT-234-overlap_record_spec_test's otherPass() and R1/R2 rows already make on
-- resetSessionCoverage). Group D's "litres still own coverage" half (D9-D12) IS driven
-- through the real hook with a true broadcast rig (no VariableWorkWidth at all). Group C's
-- reset rows (C3-C7) and Group G's grant rows (G2, G5) call _processOneDailyField and
-- _grantCropProtection directly: both are real, pre-existing SoilFertilitySystem methods
-- (not helpers this change or this bar added), and the narrow claim under test in each --
-- what the reset zeroes, and whether the grant's threshold reads the fixed fraction
-- correctly -- is exactly what a direct call on the real method proves.
--
-- WHAT IS MODELLED (as MAINT-234's world): the geometry transforms (no i3d/physics), the
-- FillType / fill-type lookups, Utils' two composition wrappers, and g_effectManager's
-- start/stopEffects as no-ops. No terrain, no g_sprayTypeManager, no SprayerRateManager:
-- groups needing those are kept to the litre math the production code itself derives
-- (HookManager.getNativeSprayRatePerHa degrades to fillScale=1, lps=1 with no
-- g_sprayTypeManager, which is real production fallback behaviour, not a bar invention).
--
-- Field geometry is chosen so the SWEPT AREA is exact rectangles on the 2 m grid (every
-- boom edge and every lane length a multiple of 2 m), so the fix's own arithmetic can be
-- checked against a hand-computed real area, not just "looks closer than before".
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/utils/DurationScaling.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, tools/test/lua/SF-1098-coverage_2m_world.lua

local OVERLAP_ON  = { enabled = true, overlapPrevention = true,  fieldBoundaryControl = false, debugMode = false }
local OVERLAP_OFF = { enabled = true, overlapPrevention = false, fieldBoundaryControl = false, debugMode = false }

local function runGroup(tag, fn)
    local ok, err = pcall(fn)
    T.eq(tag .. " the group ran to its end without a Lua error", ok and "clean" or tostring(err), "clean")
end

-- ══════════════════════════════════════════════════════════
-- A / C: ONE PASS, A 12 m BOOM OVER 100 m, A 0.12 ha FIELD (12 m x 100 m exactly)
-- ══════════════════════════════════════════════════════════
runGroup("AC", function()
    local ss, hookMgr = C2W.install("overlap", OVERLAP_OFF)
    local v = C2W.boom12({ fillType = 42 })
    local field = C2W.addField(ss, 7, 0.12)
    g_currentMission.vehicleSystem:addVehicle(v)

    -- Checkpoint at 60 of 100 m (60% real coverage): #1098's own reported shape read
    -- Pass% near 99% here. The fix must read close to the real fraction instead.
    C2W.driveLane(v, 0, 0, 0, 1, 60)
    local frac60 = field.sessionCoverageFraction
    T.ok("A1 [reached] 60 m of 100 m (60% real coverage): Pass% is " .. tostring(frac60)
         .. ", not inflated toward 1.0", frac60 > 0.45 and frac60 < 0.75)

    C2W.driveLane(v, 0, 60, 0, 1, 40)
    local fracEnd = field.sessionCoverageFraction
    T.ok("A2 NAMED: a full 12 m x 100 m pass over a 0.12 ha field reads Pass% close to 100% ("
         .. tostring(fracEnd) .. ")", fracEnd > 0.90)
    T.ok("A3 NAMED: and the swept area is close to the real 0.12 ha, not 0.20-0.36 ha "
         .. "(the 10 m cells a 12 m boom used to touch) (" .. tostring(field.sessionCoverageHa) .. " ha)",
         field.sessionCoverageHa ~= nil and field.sessionCoverageHa < 0.14)

    -- C: daily coverage counts 2 m cells the same way, and resets in _processOneDailyField.
    T.near("C1 NAMED: daily coverage (coveredAreaHa) matches session coverage, both from the "
           .. "same 2 m cells", field.coveredAreaHa, field.sessionCoverageHa, 1e-9)
    local hadDaily = C2W.countKeys(field.dailyOverlapCells)
    T.ok("C2 [reached] the daily 2 m record (dailyOverlapCells) held cells before the reset ("
         .. tostring(hadDaily) .. ")", hadDaily > 0)

    -- _processOneDailyField reads these from the batch-queue snapshot a direct call
    -- never takes; set the minimum the function needs to run its own arithmetic.
    ss._dailyBatchDay = 10
    ss._dailyBatchSeason = "SUMMER"
    ss:_processOneDailyField(7, field)
    T.eq("C3 NAMED: _processOneDailyField resets the daily area", field.coveredAreaHa, 0)
    T.eq("C4 and the daily coverage fraction", field.coverageFraction, 0)
    T.eq("C5 NAMED: and the daily 2 m record (dailyOverlapCells)", field.dailyOverlapCells, nil)
    T.eq("C6 and the session area too (a new day is a new session)", field.sessionCoverageHa, 0)
    T.eq("C7 and the session 2 m record (sessionOverlapOdo)", field.sessionOverlapOdo, nil)
end)

-- ══════════════════════════════════════════════════════════
-- B: TWO ADJACENT 12 m PASSES COVERING ABOUT 60% OF A FIELD
-- ══════════════════════════════════════════════════════════
runGroup("B", function()
    local ss, hookMgr = C2W.install("overlap", OVERLAP_ON)
    local v = C2W.boom12({ fillType = 42 })
    -- Lane 1 sweeps x in [-6, 6]; lane 2, shifted 6 m, sweeps x in [0, 12]: a union of
    -- 18 m x 100 m = 0.18 ha. A 0.30 ha field reads that as 60%.
    local field = C2W.addField(ss, 7, 0.30)
    g_currentMission.vehicleSystem:addVehicle(v)

    C2W.driveLane(v, 0, 0, 0, 1, 100)
    C2W.driveLane(v, 6, 0, 0, 1, 100)

    local frac = field.sessionCoverageFraction
    T.ok("B1 NAMED: two adjacent 12 m passes covering about 60% of a 0.30 ha field read Pass% "
         .. "near 0.6 (" .. tostring(frac) .. "), not saturated toward 100%",
         frac > 0.45 and frac < 0.75)
    T.eq("B2 NAMED: the whole-pass overlap block (coverageComplete >= 0.99) never fired",
         v._sfOverlapBlockedPass, nil)
    local suppressed = C2W.countKeys(v._sfOverlapSuppressedSections)
    T.ok("B3 and not every section is suppressed: the fresh outer edge stays on (" .. tostring(suppressed)
         .. " of 2 sections off)", suppressed < 2)
end)

-- ══════════════════════════════════════════════════════════
-- D: BROADCAST / DRY SPREADER PATH (countArea = false)
-- ══════════════════════════════════════════════════════════
runGroup("D-direct", function()
    -- D1-D8: markOverlapCells called directly (see header). countArea=false must stamp
    -- the 2 m record but add no area; countArea=true (same points) must add it, so D2-D5
    -- are shown to be the countArea=false branch and not a dead recompute.
    local ss = setmetatable({ fieldData = {} }, { __index = SoilFertilitySystem })
    local field = C2W.addField(ss, 7, 1.0)
    local veh = { _sfOdoM = 0 }
    local pts = {}
    for x = -10, 10, 2 do
        for z = -10, 10, 2 do pts[#pts + 1] = { x = x + 1, z = z + 1 } end
    end

    ss:markOverlapCells(7, pts, veh, false)
    local n = C2W.countKeys(field.sessionOverlapOdo)
    T.ok("D1 [reached] markOverlapCells(countArea=false) still stamps the 2 m record ("
         .. tostring(n) .. " cells)", n > 0)
    T.eq("D2 NAMED: and adds no session area (sessionCoverageHa)", field.sessionCoverageHa or 0, 0)
    T.eq("D3 NAMED: and no daily area (coveredAreaHa)", field.coveredAreaHa or 0, 0)
    T.eq("D4 and recomputes no session fraction", field.sessionCoverageFraction or 0, 0)
    T.eq("D5 and no daily fraction", field.coverageFraction or 0, 0)

    -- A FRESH set of points (markOverlapCells dedups per cell on first-ever stamp, so
    -- re-offering the SAME points a second time would add nothing, countArea or not).
    local pts2 = {}
    for x = 30, 50, 2 do
        for z = 30, 50, 2 do pts2[#pts2 + 1] = { x = x + 1, z = z + 1 } end
    end
    ss:markOverlapCells(7, pts2, veh, true)
    T.ok("D6 [reached] fresh points WITH countArea=true DO add session area ("
         .. tostring(field.sessionCoverageHa) .. " ha)", (field.sessionCoverageHa or 0) > 0)
    T.ok("D7 and daily area (" .. tostring(field.coveredAreaHa) .. " ha)", (field.coveredAreaHa or 0) > 0)
    -- D8: a direct call is the only way to see this recompute in isolation -- every
    -- hook-driven group also calls markBoomCells on the same tick, which recomputes
    -- these same two fractions from the same sessionCoverageHa/coveredAreaHa itself
    -- (pre-existing, unrelated to #1098), so a dead recompute here would be masked
    -- everywhere else in this bar.
    T.near("D8 NAMED: and markOverlapCells' own recompute updates sessionCoverageFraction ("
           .. tostring(field.sessionCoverageFraction) .. ")",
           field.sessionCoverageFraction, field.sessionCoverageHa / field.fieldArea, 1e-9)
    T.near("D8b and coverageFraction (" .. tostring(field.coverageFraction) .. ")",
           field.coverageFraction, field.coveredAreaHa / field.fieldArea, 1e-9)
end)

runGroup("D-hook", function()
    -- D9-D12: the real hook, a broadcast spreader with NO VariableWorkWidth at all
    -- (sectioned=false), so markOverlapRecord is called with countArea=false (as D1-D5
    -- showed adds no area) and coverage must come from the litre path instead.
    local ss, hookMgr = C2W.install("overlap", OVERLAP_OFF)
    local v = C2W.broadcast24({ fillType = 42 })
    T.eq("D9 [reached] this rig has no VariableWorkWidth sections", v.spec_variableWorkWidth, nil)
    T.eq("D10 [reached] and HookManager agrees the pass is not sectioned",
         hookMgr:_isSectionedPass(v), false)
    local field = C2W.addField(ss, 7, 0.01)
    g_currentMission.vehicleSystem:addVehicle(v)

    C2W.driveLane(v, 0, 0, 0, 1, 40)
    T.ok("D11 NAMED: the litre path still advances daily coverage for a broadcast pass ("
         .. tostring(field.coveredAreaHa) .. " ha)", (field.coveredAreaHa or 0) > 0)
    T.ok("D12 and the session coverage fraction with it (" .. tostring(field.sessionCoverageFraction)
         .. ")", (field.sessionCoverageFraction or 0) > 0)
end)

-- ══════════════════════════════════════════════════════════
-- E: THE PRODUCT-CHANGE RESET (#442, trackSprayerCoverage) STILL ZEROES THE 2 m RECORD
-- ══════════════════════════════════════════════════════════
runGroup("E", function()
    local ss, hookMgr = C2W.install("overlap", OVERLAP_OFF)
    local v = C2W.boom12({ fillType = 42 })
    local field = C2W.addField(ss, 7, 1000)   -- large: no saturation while building up ground
    g_currentMission.vehicleSystem:addVehicle(v)

    C2W.driveLane(v, 0, 0, 0, 1, 20)
    local haBefore = field.sessionCoverageHa
    local nBefore = C2W.countKeys(field.sessionOverlapOdo)
    T.ok("E0 [reached] the first product built up session area and a 2 m record ("
         .. tostring(haBefore) .. " ha, " .. tostring(nBefore) .. " cells)",
         haBefore > 0 and nBefore > 0)

    -- Switch to a different fertilizer profile (not a direct-path product: that would
    -- also route through the litre-based coverage path, which this group is not about).
    v._fillType = 41   -- LIQUIDFERTILIZER
    v.spec_sprayer.workAreaParameters.sprayFillType = 41
    C2W.place(v, 0, 20.5, 0, 1)
    C2W.tick(v, 150)

    local haAfter = field.sessionCoverageHa
    local nAfter = C2W.countKeys(field.sessionOverlapOdo)
    T.ok("E1 NAMED: the product-change reset (#442) zeroes the session area; only this tick's "
         .. "own ground remains (" .. tostring(haAfter) .. " vs " .. tostring(haBefore) .. " ha before)",
         haAfter < haBefore * 0.5)
    T.ok("E2 NAMED: and the 2 m record too (" .. tostring(nAfter) .. " vs " .. tostring(nBefore)
         .. " cells before)", nAfter < nBefore)
end)

-- ══════════════════════════════════════════════════════════
-- F: THE WIDTH FALLBACK -- FEWER THAN TWO BOOM NODES, A DECLARED WORKING WIDTH
-- ══════════════════════════════════════════════════════════
runGroup("F", function()
    local ss, hookMgr = C2W.install("overlap", OVERLAP_OFF)
    local v = C2W.fallbackRig(16, { fillType = 42 })   -- a 16 m implement, no boom nodes at all
    T.eq("F1 [reached] fewer than two boom nodes", #hookMgr:_collectBoomNodes(v), 0)
    T.eq("F2 [reached] but a declared implement working width", hookMgr:_implWorkingWidth(v), 16)
    local field = C2W.addField(ss, 7, 1000)
    g_currentMission.vehicleSystem:addVehicle(v)

    C2W.driveLane(v, 0, 0, 0, 1, 40)
    local n = C2W.countKeys(field.sessionOverlapOdo)
    T.ok("F3 NAMED: the fallback still stamps the 2 m record across the implement's width ("
         .. tostring(n) .. " cells)", n > 0)
    -- 16 m / 2 m = 8 columns, 40 m / 2 m = 20 rows: about 160 cells at 0.0004 ha each (0.064 ha).
    T.ok("F4 NAMED: and counts coverage area (one VWW section, so the pass is sectioned and "
         .. "countArea is true) (" .. tostring(field.sessionCoverageHa) .. " ha)",
         (field.sessionCoverageHa or 0) > 0.04)
end)

-- ══════════════════════════════════════════════════════════
-- G: THE 80% PROTECTION GRANT READS THE FIXED FRACTION
-- ══════════════════════════════════════════════════════════
runGroup("G", function()
    local ss, hookMgr = C2W.install("overlap", OVERLAP_OFF)
    local v = C2W.boom12({ fillType = 42 })
    -- A full 100 m pass (the real 0.12 ha a 12 m boom sweeps) is tuned to read about 85%,
    -- comfortably past COVERAGE.PROTECTION_THRESHOLD (0.80), so 70 of 100 m reads about 60%,
    -- comfortably under it.
    local field = C2W.addField(ss, 7, 0.12 / 0.85)
    g_currentMission.vehicleSystem:addVehicle(v)

    C2W.driveLane(v, 0, 0, 0, 1, 70)
    local frac60 = field.sessionCoverageFraction
    T.ok("G1 [reached] about 60% real coverage (" .. tostring(frac60) .. ")",
         frac60 > 0.45 and frac60 < 0.75)
    local granted60 = ss:_grantCropProtection(7, field, "herbicide")
    T.eq("G2 NAMED: the 80% protection grant does not open at about 60% real coverage",
         granted60, false)
    T.eq("G3 and grants no window", field.herbicideDaysLeft or 0, 0)

    C2W.driveLane(v, 0, 70, 0, 1, 30)
    local frac85 = field.sessionCoverageFraction
    T.ok("G4 [reached] about 80-85% real coverage (" .. tostring(frac85) .. ")", frac85 > 0.80)
    local granted85 = ss:_grantCropProtection(7, field, "herbicide")
    T.eq("G5 NAMED: and does open at about 80-85% real coverage", granted85, true)
    T.ok("G6 with a window (" .. tostring(field.herbicideDaysLeft) .. " days)",
         (field.herbicideDaysLeft or 0) > 0)
end)

C2W.restore()
