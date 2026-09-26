-- SF-73-target_core_spec_test.lua
--
-- The pure arithmetic of target-accurate N/P/K (Implementation v1.1 sections 4 and
-- 6), asserted against the REAL TargetNutrientCore. The Design reference models
-- (tests/SF-73-target_dose_spec_test.lua, -application_cycle_, -lifecycle_contract_)
-- carried these rows as source-free algebra; here each one runs the shipped function.
-- This file is arithmetic only: the entry-point bar is SF-73-target_entry_point_test.lua.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/target/TargetNutrientCore.lua

local C = TargetNutrientCore
local step = 100 / 254

-- ── windows ──────────────────────────────────────────────────────────────────
T.near("carrier step is (max - min) / 254", C.carrierStep(0, 100), step, 1e-12)
T.eq("an inverted layer has no step", C.carrierStep(100, 0), nil)
local w = C.window(55, step)
T.near("the window is two carrier steps wide", w.upper - w.lower, 2 * step, 1e-9)
T.near("the aim is one step below the optimum", w.aim, 55 - step, 1e-9)
T.eq("the upper edge is the crop optimum", w.upper, 55)
T.eq("no window without a finite optimum", C.window(0 / 0, step), nil)

-- ── inversion ────────────────────────────────────────────────────────────────
local u = C.litresFor(10, 1, 154.6, 0.77, 1, 1)
T.near("dry inverse forward-checks through the credit (UREA)", C.creditFor(u, 1, 154.6, 0.77, 1, 1), 10, 1e-9)
T.ok("UREA litres exceed the kilogram figure (density below 1)", u > 10 * 1000 / 154.6)
T.near("passthrough inverse", C.litresFor(10, 1, 100, 1, 1, 1), 100, 1e-9)
T.near("hectare scaling", C.litresFor(10, 0.1, 100, 1, 1, 1), 10, 1e-9)
T.near("replenishment and tuning both invert", C.litresFor(10, 1, 100, 1, 2, 2), 25, 1e-9)
T.eq("zero density refused", C.litresFor(10, 1, 100, 0, 1, 1), nil)
T.eq("infinite coefficient refused", C.litresFor(10, 1, math.huge, 1, 1, 1), nil)
T.eq("negative need refused", C.litresFor(-1, 1, 100, 1, 1, 1), nil)
T.eq("a satisfied nutrient needs zero litres", C.litresFor(0, 1, 100, 1, 1, 1), 0)

-- ── the binding nutrient ─────────────────────────────────────────────────────
do
  local l, b = C.bindingLitres({ N = 10, P = 20, K = 5 }, { N = 100, P = 100, K = 100 }, 1, 1, 1, 1)
  T.eq("the smallest participating litres bind", b, "K")
  T.near("and set the target", l, 50, 1e-9)
  local _, tie = C.bindingLitres({ N = 10, P = 10, K = 10 }, { N = 100, P = 100, K = 100 }, 1, 1, 1, 1)
  T.eq("ties bind in the order N, P, K", tie, "N")
  local _, tieP = C.bindingLitres({ N = 10, P = 10, K = 10 }, { N = 0, P = 100, K = 100 }, 1, 1, 1, 1)
  T.eq("a zero coefficient does not constrain (tie falls to P)", tieP, "P")
  local lz, bz = C.bindingLitres({ N = 0, P = 20, K = 20 }, { N = 50, P = 100, K = 0 }, 1, 1, 1, 1)
  T.eq("a supplied, already satisfied nutrient binds at zero", lz, 0)
  T.eq("and is named as binding", bz, "N")
  local ln, _, _, why = C.bindingLitres({ N = 5 }, { N = 0, P = 0, K = 0 }, 1, 1, 1, 1)
  T.eq("a blend with no N/P/K has no target", ln, nil)
  T.eq("and says why", why, "NO_NPK")
  local li, _, _, whyI = C.bindingLitres({ N = nil, P = 1, K = 1 }, { N = 10, P = 10, K = 10 }, 1, 1, 1, 1)
  T.eq("an unknown reading on a supplied nutrient is not a target", li, nil)
  T.eq("and is INVALID", whyI, "INVALID")
end

-- ── the final quantity ───────────────────────────────────────────────────────
do
  T.eq("the target wins under the caps", (C.accept(10, 20, 100, 1)), 10)
  T.eq("a modifier cannot exceed the target", (C.accept(10, 20, 100, 1.5)), 10)
  T.eq("a modifier cannot exceed the native cap", (C.accept(30, 20, 100, 1.5)), 20)
  T.eq("suppression lowers the cap first", (C.accept(30, 20, 100, 0.5)), 10)
  T.eq("a limited tank", (C.accept(10, 20, 4, 1)), 4)
  T.eq("helper buy has no artificial stock limit", (C.accept(10, 20, nil, 1)), 10)
  T.eq("an invalid modifier is refused", (C.accept(10, 20, 100, -1)), nil)
  local _, lim = C.accept(10, 20, 4, 1)
  T.ok("a supply-limited quantity names SUPPLY", lim.supply and not lim.hardware)
  local _, limH = C.accept(30, 20, 100, 1)
  T.ok("a cap-limited quantity names HARDWARE", limH.hardware and not limH.supply)
  local _, limN = C.accept(10, 20, 100, 1)
  T.ok("a target-limited quantity names neither", not limN.hardware and not limN.supply)
end

-- ── the display precedence ───────────────────────────────────────────────────
T.eq("binding shortage is not success", C.displayState({ SHORT_BINDING = true }), "SHORT_BINDING")
T.eq("supply wins over binding", C.displayState({ SHORT_SUPPLY = true, SHORT_BINDING = true }), "SHORT_SUPPLY")
T.eq("a failure overrides a predicted success", C.displayState({ APPLICATION_FAILED = true, REACHED = true }), "APPLICATION_FAILED")
T.eq("quantized deficiency is explicit", C.displayState({ SHORT_QUANTIZED = true }), "SHORT_QUANTIZED")
T.eq("inside the window may already be reached", C.displayState({ REACHED = true }), "REACHED")
T.eq("undetermined outranks inactive", C.displayState({ INACTIVE = true, UNDETERMINED = true }), "UNDETERMINED")
T.eq("hardware outranks binding", C.displayState({ SHORT_BINDING = true, SHORT_HARDWARE = true }), "SHORT_HARDWARE")
T.eq("no flag is undetermined", C.displayState({}), "UNDETERMINED")

-- ── relationships ────────────────────────────────────────────────────────────
do
  local win = C.window(40, step)
  T.eq("above the optimum is ABOVE", (C.relationship(40.5, win)), "ABOVE")
  T.eq("the optimum itself is IDEAL", (C.relationship(40, win)), "IDEAL")
  T.eq("the lower edge is IDEAL", (C.relationship(win.lower, win)), "IDEAL")
  local rel, dist, width = C.relationship(win.lower - win.width * 0.5, win)
  T.eq("half a window below the lower edge is APPROACHING", rel, "APPROACHING")
  T.near("with its distance", dist, win.width * 0.5, 1e-9)
  T.near("and the window width", width, 2 * step, 1e-9)
  T.eq("one full window below is still APPROACHING", (C.relationship(win.lower - win.width, win)), "APPROACHING")
  T.eq("further down is BELOW", (C.relationship(win.lower - win.width - 0.01, win)), "BELOW")
  T.eq("an unknown value is UNDETERMINED", (C.relationship(nil, win)), "UNDETERMINED")
end

-- ── the decimal sequence ─────────────────────────────────────────────────────
T.ok("decimal strings compare without float conversion", C.seqGreater("100000000000000000", "99999999999999999"))
T.ok("leading zeros do not defeat the order", not C.seqGreater("0002", "2"))
T.ok("a strictly greater sequence is greater", C.seqGreater("12", "9"))
T.ok("an equal sequence is not greater", not C.seqGreater("7", "7"))
T.ok("a non-decimal string is never greater", not C.seqGreater("1e3", "2"))
T.ok("an over-long sequence is refused", not C.seqGreater(string.rep("9", 19), "1"))
T.eq("next of 9 carries", C.seqNext("9"), "10")
T.eq("next of 1099 carries one digit", C.seqNext("1099"), "1100")
T.eq("next at the bound is nil (a new epoch)", C.seqNext(string.rep("9", 18)), nil)
T.eq("next normalises leading zeros", C.seqNext("007"), "8")

-- ── the owning crop table ────────────────────────────────────────────────────
do
  local targets, per, al = SoilConstants.CROP_NUTRIENT_TARGETS, SoilConstants.PERENNIAL_FORAGE_NAMES, SoilConstants.SF73_CROP_ALIASES
  T.eq("wheat is supported", C.resolveCropKey("WHEAT", targets, per, al), "wheat")
  T.eq("shipped PEA resolves to the peas row", C.resolveCropKey("PEA", targets, per, al), "peas")
  T.eq("shipped GREENBEAN resolves to the beans row", C.resolveCropKey("GREENBEAN", targets, per, al), "beans")
  T.eq("perennial forage is excluded even with a row (luzerne)", C.resolveCropKey("LUZERNE", targets, per, al), nil)
  T.eq("clover is excluded", C.resolveCropKey("CLOVER", targets, per, al), nil)
  T.eq("grass is excluded", C.resolveCropKey("GRASS", targets, per, al), nil)
  T.eq("default agronomy is never a supported crop", C.resolveCropKey("DEFAULT", targets, per, al), nil)
  T.eq("an unlisted crop is unsupported", C.resolveCropKey("POPLAR", targets, per, al), nil)
  T.eq("no name, no crop", C.resolveCropKey(nil, targets, per, al), nil)
  local wins = C.cropWindows(targets.wheat, { N = { min = 0, max = 100 }, P = { min = 0, max = 100 }, K = { min = 0, max = 100 } })
  T.eq("the wheat N window's upper is its optimum", wins.N.upper, 55)
  T.near("the wheat P window's lower is two steps under", wins.P.lower, 40 - 2 * step, 1e-9)
end

-- ── copies ───────────────────────────────────────────────────────────────────
do
  local src = { a = { b = 1 } }
  local cp = C.copy(src)
  cp.a.b = 2
  T.eq("a copied result never aliases the host's", src.a.b, 1)
end

T.summary()
