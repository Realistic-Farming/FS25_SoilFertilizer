-- compaction_decay_test.lua - persistence of compaction recovery (nemrod153 Discord report).
-- Natural decay and taproot bio-drilling shave points off the field-average compaction.
-- The average is DERIVED as compactionSum / compactionTotalCells, so the old code (which
-- only lowered field.compaction) was silently wiped the instant onCompaction /
-- onSubsoilerPass re-derived the average from the untouched compactionSum - that is the
-- nemrod153 "radish decompaction reset the moment I started subsoiling" report.
-- _applyCompactionDecay must fade compactionSum so the recovery survives a later rewrite.
--
-- SF-2m-compaction CHANGED ROW: compaction moved to the 2 m value map, so the per-cell
-- zoneData fade this file originally pinned no longer exists (_applyCompactionDecay no
-- longer touches field.zoneData at all; the map fade on a THIRD fieldId argument runs
-- through _compactionMapFade/the held MAP_DECAY_STEP ratio instead, covered end to end
-- by SF-2m-compaction_entry_test.lua's D1-D4). The claim that moved here: the pending
-- map-fade ratio (field._compactionMapRatio) still accumulates the same ratio the
-- average takes, even with no fieldId/valueMaps (the bookkeeping line is unconditional;
-- only the actual map write is gated on fieldId~=nil and vmAvailable()).
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua

local function sys()
  return setmetatable({ settings = {} }, { __index = SoilFertilitySystem })
end

-- A field compacted over 4 tracked cells (the other cells implicitly 0). Set up so the
-- accounting total and the per-cell store agree: sum 160 over 4 cells → average 40.
local function makeField()
  return {
    compaction           = 40,
    compactionSum        = 160,
    compactionTotalCells = 4,
    zoneData = {
      ["1"] = { compaction = 40 },
      ["2"] = { compaction = 40 },
      ["3"] = { compaction = 40 },
      ["4"] = { compaction = 40 },
    },
  }
end

-- Re-derive the field average the way onCompaction (4632) and onSubsoilerPass (4685) do.
-- This is the operation that erased the old decay.
local function rederive(f)
  return f.compactionSum / f.compactionTotalCells
end

-- 1. A 4-point decay (oldAvg 40 → 36, ratio 0.9) lands on the average...
local f = makeField()
local changed = sys():_applyCompactionDecay(f, 4)
T.ok("decay reports a change", changed == true)
T.near("average dropped by the reduction", f.compaction, 36)

-- 2. ...AND on compactionSum, so re-deriving the average keeps the recovery.
T.near("compactionSum faded proportionally", f.compactionSum, 144)
T.near("REGRESSION: re-derived average survives (was snapping back to 40)", rederive(f), 36)
-- CHANGED (was "cell value faded proportionally" on zoneData, which this change
-- retires): the held map-fade ratio tracks the same 0.9 the average took, with no
-- fieldId/valueMaps here to actually write it.
T.near("CHANGED: the pending map-fade ratio tracks the same fade (0.9)", f._compactionMapRatio, 0.9)

-- 3. Stacking decays (e.g. several winter days) keeps shrinking and stays consistent.
sys():_applyCompactionDecay(f, 6)   -- 36 → 30, ratio 30/36
T.near("second decay lowers the average", f.compaction, 30)
T.near("re-derived average still matches after stacking", rederive(f), 30)
T.near("CHANGED: the pending ratio keeps compounding (0.9 * 30/36 = 0.75)", f._compactionMapRatio, 0.75)

-- 4. A reduction larger than the current average clamps everything to zero.
local g = makeField()
sys():_applyCompactionDecay(g, 999)
T.eq("over-decay clamps average to 0", g.compaction, 0)
T.eq("over-decay clamps compactionSum to 0", g.compactionSum, 0)
T.eq("over-decay clamps re-derived average to 0", rederive(g), 0)

-- 5. No-ops: nothing to decay, or a non-positive reduction, leave the field untouched.
local h = makeField()
T.ok("zero reduction is a no-op", sys():_applyCompactionDecay(h, 0) == false)
T.near("compactionSum unchanged on no-op", h.compactionSum, 160)

local z = { compaction = 0, compactionSum = 0, compactionTotalCells = 4, zoneData = {} }
T.ok("decay on an uncompacted field is a no-op", sys():_applyCompactionDecay(z, 5) == false)

T.summary()
