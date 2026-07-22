-- map_overlay_cell_semantics_test.lua - the LEGACY zoneData render path of the
-- soil map overlay, which runs only when neither the runtime value maps nor the
-- GRLE info layers are available on a terrain.
--
-- After the Refined graft, markBoomCells writes ONLY weed / pest / disease /
-- compaction onto a zoneData cell; N, P, K, pH and OM live on the per-pixel value
-- maps and never reach a cell. The overlay treats a non-nil per-cell value as the
-- "measured" flag and draws it at FULL OPACITY, so any layer that fabricates a
-- value from the absent nutrients paints a confident lie over every cell a boom
-- has ever crossed.
--
-- Two properties are locked here:
--   1. Layers 1-6 (N/P/K/pH/OM/urgency) must return nil so the caller falls back
--      to the field average. Urgency especially: it used to compute
--      100 - (N+P+K)/3 from nil-defaulted-to-zero nutrients, which is a constant
--      MAXIMUM urgency at full opacity.
--   2. The merge item 3 discovery gate must hold here too. This path does not
--      flow through _vmDisplayValues, so it needs its own gate or an unscouted
--      field leaks its disease on exactly the maps the scouting economy sells.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/ui/SoilMapOverlay.lua

local getCellValue = SoilMapOverlay._getCellLayerValue

-- A cell as markBoomCells actually writes it: biotics + compaction, no nutrients.
local function boomCell()
  return {
    weedPressure    = 42,
    pestPressure    = 31,
    diseasePressure = 66,
    compaction      = 18,
  }
end

local function field(discovered)
  return { diseaseDiscovered = discovered }
end

local scouted   = field(true)
local unscouted = field(false)

-- ── 1. Nutrient layers have no per-cell truth ────────────────────────────────
-- Each must be nil, which is what routes the caller to the dimmed field average.
local cell = boomCell()
T.ok("layer 1 (N) has no per-cell value",  getCellValue(cell, 1, scouted) == nil)
T.ok("layer 2 (P) has no per-cell value",  getCellValue(cell, 2, scouted) == nil)
T.ok("layer 3 (K) has no per-cell value",  getCellValue(cell, 3, scouted) == nil)
T.ok("layer 4 (pH) has no per-cell value", getCellValue(cell, 4, scouted) == nil)
T.ok("layer 5 (OM) has no per-cell value", getCellValue(cell, 5, scouted) == nil)

-- ── 2. Urgency must not be fabricated from the missing nutrients ─────────────
-- The regression: nil N/P/K defaulted to 0 gave 100 - 0 = 100, a non-nil value,
-- so every boom-touched cell rendered as maximum urgency at full opacity.
local urgency = getCellValue(cell, 6, scouted)
T.ok("layer 6 (urgency) is not computed from absent nutrients", urgency == nil)
T.ok("layer 6 does not return the fabricated maximum", urgency ~= 100)

-- A cell that somehow carries stale nutrient keys must still not be trusted,
-- because the field average is the only correct source on this path.
local stale = boomCell()
stale.N, stale.P, stale.K = 10, 10, 10
T.ok("stale N key on a cell is ignored",      getCellValue(stale, 1, scouted) == nil)
T.ok("stale nutrients do not revive urgency", getCellValue(stale, 6, scouted) == nil)

-- ── 3. The layers that DO have per-cell truth still report it ────────────────
T.near("layer 7 (weed) reads the cell",       getCellValue(cell, 7,  scouted), 42, 0.001)
T.near("layer 8 (pest) reads the cell",       getCellValue(cell, 8,  scouted), 31, 0.001)
T.near("layer 10 (compaction) reads the cell", getCellValue(cell, 10, scouted), 18, 0.001)

-- ── 4. The discovery gate holds on this path ─────────────────────────────────
T.near("scouted disease reads its real pressure",
  getCellValue(cell, 9, scouted), 66, 0.001)
T.near("UNSCOUTED disease reads healthy, identical to a clean field",
  getCellValue(cell, 9, unscouted), 0, 0.001)
T.near("a field that has never been scouted reads healthy",
  getCellValue(cell, 9, field(nil)), 0, 0.001)

-- Pest has no discovery concept and must show through regardless.
T.near("pest is never gated by discovery",
  getCellValue(cell, 8, unscouted), 31, 0.001)

-- A clean scouted field and an unscouted infected field must be indistinguishable.
local clean = boomCell()
clean.diseasePressure = 0
T.eq("unscouted infection is indistinguishable from clean ground",
  getCellValue(cell, 9, unscouted), getCellValue(clean, 9, scouted))

-- ── 5. Unknown layers stay nil ───────────────────────────────────────────────
-- Layer 11 (yield) has no cell backing and the caller's legacy branch only spans
-- 1-10; both must resolve to the field-average path rather than a stray value.
T.ok("layer 11 (yield) has no per-cell value", getCellValue(cell, 11, scouted) == nil)
T.ok("layer 0 (off) has no per-cell value",    getCellValue(cell, 0,  scouted) == nil)

T.summary()
