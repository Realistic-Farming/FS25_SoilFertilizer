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
local twoRowsAt, recordCellsInFrame = ORW.twoRowsAt, ORW.recordCellsInFrame

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
-- A: ANY HEADING. The record is laid in the sprayer's own frame, so a lane at 45 degrees to
-- the world axes is stamped across its whole boom and only along its own boom line.
-- ══════════════════════════════════════════════════════════
local S45 = math.sqrt(0.5)
do
    -- Lane 2 22.5 m across (1.5 m of overlap): section 9's tip 1.5 m inside lane 1's sprayed
    -- ground, section 8's 1.5 m outside it. A 2 m cell on a grid turned 45 degrees to the lane
    -- reaches up to 1.41 m past the boom's edge, so a tip further out than that is never off.
    -- The turn is not sprayed, so only lane 1's record can switch a section off.
    local ss, _, v = install("overlap", OVERLAP_ON)
    local off = twoRowsAt(v, 0, 0, S45, S45, 22.5, nil, true)
    T.eq("A1 two rows at 45 degrees: only the section whose tip is over lane 1's ground switches off",
         list(off), "9")
end
do
    -- One lane at 45 degrees, stopped: where is the record, in the sprayer's last frame? The
    -- lane ends at 30.5 m, where the 2 m grid (turned 45 degrees to it) has cell centres 0.61 m
    -- ahead of the root, 1.08 m ahead of the boom line: past the half-cell band the record
    -- keeps, inside what a cell merely touched by the line, or the root's line, would stamp.
    local ss, _, v = install("overlap", OVERLAP_ON)
    driveLane(v, 0, 0, S45, S45, 30.5)
    local rx, rz = 30.5 * S45, 30.5 * S45
    local ahead, outer, beyond = 0, 0, 0
    local half = SoilConstants.ZONE.OVERLAP_CELL_SIZE / 2
    for _, c in ipairs(recordCellsInFrame(ss, rx, rz, S45, S45)) do
        if c.fwd > ORW.BOOM_FWD + half + 1e-6 then ahead = ahead + 1 end
        if math.abs(c.lat) >= 10 then outer = outer + 1 end
        if math.abs(c.lat) > 12 + 1e-6 then beyond = beyond + 1 end
    end
    T.eq("A2 lane end at 45 degrees: no recorded cell's centre lies more than half a cell ahead of the last boom line",
         ahead, 0)
    T.ok("A3 and the record reaches the boom's outer metres on both sides (" .. outer .. " cells past 10 m out)",
         outer > 0)
    T.eq("A4 and no recorded cell's centre lies past the boom's ends", beyond, 0)
end

-- ══════════════════════════════════════════════════════════
-- W: GROUND ONLY SWITCHED-OFF SECTIONS COVERED IS NOT RECORDED (Option B)
-- ══════════════════════════════════════════════════════════
do
    -- Lane 1's two outer sections on lane 2's side (tips 9 and 12 m out) are switched off
    -- before the tick, as a section-control mod leaves them, and back on before the turn. So
    -- lane 1 sprayed only to 6 m out, and lane 2's section 9 (tip 10 m out) is over fresh ground.
    -- The centre section is given a tip node (1.5 m): with none its ground is unknown, and a
    -- spraying section of unknown ground keeps every point (MAINTENANCE row 229's rule). The
    -- turn is not sprayed, so lane 2 meets only lane 1's record.
    local ss, _, v = install("overlap", OVERLAP_ON)
    local secs = v.spec_variableWorkWidth.sections
    secs[5].maxWidthNode = "mw5"
    secs[8].isActive, secs[9].isActive = false, false
    local off = twoRowsAt(v, 2, 0, 0, 1, 22, function()
        secs[8].isActive, secs[9].isActive = true, true
    end, true)
    T.eq("W1 lane 1's switched-off sections left no record, so lane 2 keeps every section on", list(off), "")
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
