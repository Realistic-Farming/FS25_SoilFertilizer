-- compaction_decay_test.lua — persistence of compaction recovery (nemrod153 Discord report).
-- Natural decay and taproot bio-drilling shave points off the field-average compaction.
-- The average is DERIVED as compactionSum / compactionTotalCells, so the old code (which
-- only lowered field.compaction) was silently wiped the instant onCompaction /
-- onSubsoilerPass re-derived the average from the untouched compactionSum — that is the
-- nemrod153 "radish decompaction reset the moment I started subsoiling" report.
-- _applyCompactionDecay must fade compactionSum AND every zoneData cell so the recovery
-- survives a later per-cell rewrite.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/SoilFertilitySystem.lua

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

-- 2. ...AND on compactionSum + every cell, so re-deriving the average keeps the recovery.
T.near("compactionSum faded proportionally", f.compactionSum, 144)
T.near("cell value faded proportionally", f.zoneData["1"].compaction, 36)
T.near("REGRESSION: re-derived average survives (was snapping back to 40)", rederive(f), 36)

-- 3. Stacking decays (e.g. several winter days) keeps shrinking and stays consistent.
sys():_applyCompactionDecay(f, 6)   -- 36 → 30, ratio 30/36
T.near("second decay lowers the average", f.compaction, 30)
T.near("re-derived average still matches after stacking", rederive(f), 30)

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
