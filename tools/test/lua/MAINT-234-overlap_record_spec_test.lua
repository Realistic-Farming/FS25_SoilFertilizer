-- MAINT-234-overlap_record_spec_test.lua
--
-- MAINTENANCE row 234 (Tyson's option (a)): overlap prevention reads its own finer record.
--
-- THE DEFECT THIS PINS (development 54407c80; aussieyoda, SF-1032; Bob's correction to his
-- green-square trace): both overlap checks (overlap prevention, and the field-boundary
-- control's copy) switched a whole section off when the 10 m session cell under its tip had
-- been stamped by an earlier pass. A cell is stamped whole when any part of a boom sweep
-- touches it, so when the next row's section tip landed in a cell the previous row only
-- grazed, that section switched off over ground nobody sprayed. With a 24 m boom and 2 m of
-- overlap, three sections (about 7 m of boom) went off where one should.
--
-- THE FIX: a 2 m record (ZONE.OVERLAP_CELL_SIZE), stamped beside every markBoomCells call
-- from the same boom nodes, only cells whose centre the boom covers, on the boom's own line;
-- both checks read it at the tip. Server only, never saved, cleared where the session cells
-- are cleared. The 10 m cells, and everything read from them (the green square, pass %, the
-- protection grants, the panel's 80% colour), are unchanged.
--
-- THE ENTRY-POINT BAR: every row installs production's own appends in production's order and
-- drives the class Sprayer.onStartWorkAreaProcessing / onEndWorkAreaProcessing (the world is
-- MAINT-234-overlap_record_world.lua). Every stamp of this sprayer comes from the production
-- append; another vehicle's pass is written by the production writer. Asserted: the sections
-- either check switched off, and the 10 m record.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, tools/test/lua/MAINT-234-overlap_record_world.lua

local install, driveLane, twoRows, list, tenMetreSignature, otherPass =
    ORW.install, ORW.driveLane, ORW.twoRows, ORW.list, ORW.tenMetreSignature, ORW.otherPass

local OVERLAP_ON  = { enabled = true, overlapPrevention = true,  fieldBoundaryControl = false, debugMode = false }
local OVERLAP_OFF = { enabled = true, overlapPrevention = false, fieldBoundaryControl = false, debugMode = false }
local BOUNDARY_ON = { enabled = true, overlapPrevention = false, fieldBoundaryControl = true,
                      smartSensorEnabled = false, debugMode = false }

-- ══════════════════════════════════════════════════════════
-- N: TWO ROWS WITH 2 M OF OVERLAP (the reported case)
-- ══════════════════════════════════════════════════════════
local sigOn
do
    local ss, _, v = install("overlap", OVERLAP_ON)
    local off = twoRows(v)
    T.eq("N1 lane 2 overlaps lane 1 by 2 m: only the section whose tip is over lane 1's ground switches off",
         list(off), "9")
    sigOn = tenMetreSignature(ss)
    local n = 0
    for _ in pairs(ss.fieldData[7].sessionOverlapOdo or {}) do n = n + 1 end
    T.ok("N1b and the overlap record was stamped by the production append", n > 0)
end
do
    local ss, _, v = install("overlap", OVERLAP_OFF)
    twoRows(v)
    T.eq("N2 the 10 m record (cells, pass %, daily cells, green square) is the same with the check off",
         tenMetreSignature(ss), sigOn)
end
-- The same drive's 10 m record as development 54407c80 produced it, before this PR (captured
-- by running this bar against that commit's src): the record and everything read from it are
-- unchanged.
T.eq("N2b the 10 m record is identical to development 54407c80's own output", sigOn,
     "cells=36 [-10000 -9994 -9995 -9996 -9997 -9998 -9999 0 1 10000 10001 10002 10003 10004 10005 10006 10007 2 20001 20002 20003 20004 20005 20006 20007 3 30001 30002 30003 30004 30005 30006 4 5 6 7] sessionHa=0.3600 sessionFrac=0.000360 daily=36 coveredHa=0.3600 trail=36")
do
    local ss, _, v = install("boundary", BOUNDARY_ON)
    local off = twoRows(v)
    T.eq("N3 field-boundary control's overlap copy reads the same record: only section 9", list(off), "9")
end

-- ══════════════════════════════════════════════════════════
-- O: ANOTHER VEHICLE'S PASS, AT THE RECORD'S RESOLUTION
-- It covered x in [-20, 14); this sprayer heads south at x = 24, so section 9's tip is at
-- x 12 (over that pass) and section 8's at x 15 (2 m clear of it).
-- ══════════════════════════════════════════════════════════
do
    local ss, _, v = install("overlap", OVERLAP_ON)
    otherPass(ss, {}, -20, 14, 0, 60)
    local off = driveLane(v, 24, 50, 0, -1, 30)
    T.eq("O1 another vehicle's ground counts at once, and only under the tip that is over it", list(off), "9")
end

-- ══════════════════════════════════════════════════════════
-- R: THE RECORD IS CLEARED WHERE THE SESSION CELLS ARE
-- ══════════════════════════════════════════════════════════
do
    local ss, _, v = install("overlap", OVERLAP_ON)
    driveLane(v, 2, 0, 0, 1, 20)
    ss:resetSessionCoverage(7, "test")
    T.eq("R1 resetSessionCoverage clears the overlap record with the session cells",
         tostring(ss.fieldData[7].sessionOverlapOdo) .. "/" .. tostring(next(ss.fieldData[7].sessionCoverageCells)),
         "nil/nil")
    driveLane(v, 2, 20, 0, 1, 20)
    ss.fieldData[7].sessionLastProduct = "FERTILIZER"
    ss:trackSprayerCoverage(7, 1, "LIQUIDFERTILIZER", false, nil)
    T.eq("R2 a product change in trackSprayerCoverage clears it too",
         tostring(ss.fieldData[7].sessionOverlapOdo), "nil")
end

ORW.restore()
