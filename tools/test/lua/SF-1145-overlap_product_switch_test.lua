-- SF-1145-overlap_product_switch_test.lua
--
-- THE DEFECT THIS PINS (#1145, joeynuggetz): once a product's own pass has already
-- stamped the overlap record over a field's ground, Overlap Prevention's per-tip
-- check (HookManager.isOverlapCellSprayedEarlier) blocks a DIFFERENT product driving
-- the same ground too - exactly as it should for the SAME product, but nothing told
-- the gate the product had changed. The ordinary product-change reset
-- (SoilFertilitySystem:trackSprayerCoverage's #442 clear) only fires once a tick
-- actually sprays (liters > 0), and the overlap check can hold liters at 0 forever
-- once every cell the new product's boom crosses is already stamped by the old one:
-- a deadlock with no way out until day change or plowing. The field's own log
-- ("[OverlapPrev] suppressed 12 sections" on every tick, no nutrients/coverage/
-- billing) matched this exactly.
--
-- THE FIX: HookManager's two overlap gates (installOverlapPreventionHook, the one the
-- log matched, and installSectionControlHook's own copy) each clear the field's
-- overlap/coverage state the moment the PENDING fill type differs from
-- field.sessionLastProduct, through the new SoilFertilitySystem:clearOverlapOnProductChange,
-- before the per-section suppression loop reads the stale record. A same-product
-- pass is untouched: the clear only fires on an actual switch.
--
-- THE ENTRY-POINT BAR: reuses MAINT-234-overlap_record_world.lua's harness (a 9-section
-- Hardi laid out exactly as RSF-836), driving Sprayer.onStartWorkAreaProcessing /
-- onEndWorkAreaProcessing through production's own installed hooks, in production's
-- order. The "earlier pass" ground is stamped by a different vehicle through the
-- production writer (otherPass, MAINT-234's own O1 geometry), so there is no grace-
-- period ambiguity about the test sprayer revisiting its own very recent ground - the
-- only variable between the baseline and the switch case is the product.
--
-- A second fill type (POTASH) is registered locally: the shared world only names
-- FERTILIZER, and both are already on installOverlapPreventionHook's hardcoded
-- trackable list, so the gate treats a switch between them as a genuine product
-- change, not an untracked fill type falling out of the gate entirely.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, tools/test/lua/MAINT-234-overlap_record_world.lua

local install, driveLane, otherPass, list = ORW.install, ORW.driveLane, ORW.otherPass, ORW.list

-- Extend the shared world's fill-type mock with a second trackable product. Nothing
-- else in this file (or the shared world) resets g_fillTypeManager once it is set, so
-- this sticks for every install() call below.
do
    local origByName, origByIndex = g_fillTypeManager.getFillTypeByName, g_fillTypeManager.getFillTypeByIndex
    g_fillTypeManager.getFillTypeByName = function(self, n)
        if n == "POTASH" then return { index = 43, name = "POTASH" } end
        return origByName(self, n)
    end
    g_fillTypeManager.getFillTypeByIndex = function(self, i)
        if i == 43 then return { index = 43, name = "POTASH" } end
        return origByIndex(self, i)
    end
end

local OVERLAP_ON  = { enabled = true, overlapPrevention = true,  fieldBoundaryControl = false, debugMode = false }
local BOUNDARY_ON = { enabled = true, overlapPrevention = false, fieldBoundaryControl = true,
                      smartSensorEnabled = false, debugMode = false }

-- ══════════════════════════════════════════════════════════
-- D: installOverlapPreventionHook, the gate the report's own log matched
-- ══════════════════════════════════════════════════════════
do
    -- Baseline (control): the SAME product driving over ground an earlier pass
    -- stamped is blocked, exactly as MAINT-234's O1 already proves - this is not new
    -- behaviour, just the starting point the switch case is compared against.
    local ss, _, v = install("overlap", OVERLAP_ON)
    otherPass(ss, {}, -20, 14, 0, 60)
    ss.fieldData[7].sessionLastProduct = "FERTILIZER"
    v.spec_sprayer.workAreaParameters.sprayFillType = 42
    local off1 = driveLane(v, 24, 50, 0, -1, 30)
    T.eq("D1 same product (FERTILIZER) over ground an earlier pass stamped: section 9 blocked",
         list(off1), "9")
end
do
    -- The switch: the same stamped ground, but the field's last product was
    -- FERTILIZER and this pass is POTASH. Without the fix this blocks forever
    -- (liters never reaches the #442 reset); with it, nothing is suppressed.
    local ss, _, v = install("overlap", OVERLAP_ON)
    otherPass(ss, {}, -20, 14, 0, 60)
    ss.fieldData[7].sessionLastProduct = "FERTILIZER"
    v.spec_sprayer.workAreaParameters.sprayFillType = 43
    -- The mock's getFillUnitFillType (what installSprayerAreaHook reads for
    -- trackSprayerCoverage, a separate resolution from wap.sprayFillType, which the
    -- overlap gate itself reads) is a fixed stub at 42 from newHardi(); keep it
    -- consistent with the switch, as the real engine's two reads always agree.
    v.getFillUnitFillType = function() return 43 end
    local off2 = driveLane(v, 24, 50, 0, -1, 30)
    T.eq("D2 switching to POTASH over the same stamped ground: nothing is suppressed",
         list(off2), "")
    T.eq("D2b and the field now tracks the new product", ss.fieldData[7].sessionLastProduct, "POTASH")
end

-- ══════════════════════════════════════════════════════════
-- B: installSectionControlHook's own copy of the same check
-- ══════════════════════════════════════════════════════════
do
    local ss, _, v = install("boundary", BOUNDARY_ON)
    otherPass(ss, {}, -20, 14, 0, 60)
    ss.fieldData[7].sessionLastProduct = "FERTILIZER"
    v.spec_sprayer.workAreaParameters.sprayFillType = 42
    local off1 = driveLane(v, 24, 50, 0, -1, 30)
    T.eq("B1 field-boundary control's overlap copy: same product, section 9 blocked", list(off1), "9")
end
do
    local ss, _, v = install("boundary", BOUNDARY_ON)
    otherPass(ss, {}, -20, 14, 0, 60)
    ss.fieldData[7].sessionLastProduct = "FERTILIZER"
    v.spec_sprayer.workAreaParameters.sprayFillType = 43
    local off2 = driveLane(v, 24, 50, 0, -1, 30)
    T.eq("B2 switching product clears this copy's stale record too", list(off2), "")
end

ORW.restore()
