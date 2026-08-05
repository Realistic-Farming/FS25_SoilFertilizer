-- text_fitting_771_test.lua - text fitting for the raw renderText surfaces (#771).
--!load: src/utils/UIHelper.lua
--
-- The behaviour under test is a port of the base game's TextElement RESIZE mode
-- (gui/elements/TextElement.lua:479-490): shrink by 5 percent of the requested
-- size per step until the text fits, floor at a minimum size, and only then
-- truncate with an ellipsis.
--
-- The engine text functions are mocked here rather than in the shared prelude,
-- so nothing else in the suite changes behaviour. The mock is deliberately
-- linear: width = size * charCount * 10. That exercises every branch; real
-- glyph measurement is the engine's problem, not this test's.

local CHAR_W = 10

_G.getTextWidth = function(size, text) return size * #tostring(text) * CHAR_W end
_G.renderText = function(x, y, size, text)
  _G.__lastRender = { x = x, y = y, size = size, text = text }
end

_G.Utils = _G.Utils or {}
_G.Utils.limitTextToWidth = function(text, size, width, _trimFront, mark)
  local per = size * CHAR_W
  if per <= 0 then return text end
  local room = math.floor(width / per) - #mark
  if room < 0 then room = 0 end
  if room >= #text then return text end
  return string.sub(text, 1, room) .. mark
end

local function widthOf(text, size) return getTextWidth(size, text) end

local SIZE = 0.010
local FLOOR = SIZE * UIHelper.TEXT_MIN_SIZE_FACTOR

-- ── text that already fits is left completely alone ──────────
do
  local text, size = UIHelper.fitText("Soil", SIZE, widthOf("Soil", SIZE) + 1)
  T.eq("fits: text unchanged", text, "Soil")
  T.eq("fits: size unchanged", size, SIZE)
end

-- ── a mild overflow shrinks rather than cutting ──────────────
do
  local long = "Bodenfeuchtigkeit"
  local fitted, size = UIHelper.fitText(long, SIZE, 1.6)
  T.eq("mild overflow: text is NOT cut", fitted, long)
  T.ok("mild overflow: size came down", size < SIZE)
  T.ok("mild overflow: size stayed at or above the floor", size >= FLOOR - 1e-9)
  T.ok("mild overflow: the shrunk text actually fits", widthOf(fitted, size) <= 1.6 + 1e-9)
end

-- ── past the floor it truncates, and only then ───────────────
do
  local veryLong = string.rep("A", 60)
  local cut, size = UIHelper.fitText(veryLong, SIZE, 1.0)
  T.ok("floor: size never drops below the minimum", size >= FLOOR - 1e-9)
  T.ok("floor: text is truncated once shrinking is exhausted", #cut < #veryLong)
  T.eq("floor: truncation leaves an ellipsis", cut:sub(-3), UIHelper.TEXT_ELLIPSIS)
  T.ok("floor: the truncated text fits", widthOf(cut, size) <= 1.0 + 1e-9)
end

-- ── more room keeps at least as much text ────────────────────
-- The property that stops a word being cut in half when it did not need to be.
do
  local veryLong = string.rep("A", 60)
  local narrow = UIHelper.fitText(veryLong, SIZE, 1.0)
  local wider  = UIHelper.fitText(veryLong, SIZE, 2.0)
  T.ok("a wider box keeps at least as many characters", #wider >= #narrow)
end

-- ── guards: fitting is opt-in and must never break a caller ──
do
  local a, aS = UIHelper.fitText("Soil", SIZE, nil)
  T.eq("nil maxWidth: text untouched", a, "Soil")
  T.eq("nil maxWidth: size untouched", aS, SIZE)

  local b, bS = UIHelper.fitText("Soil", SIZE, 0)
  T.eq("zero maxWidth: text untouched", b, "Soil")
  T.eq("zero maxWidth: size untouched", bS, SIZE)

  local c, cS = UIHelper.fitText("", SIZE, 1.0)
  T.eq("empty string: returned as-is", c, "")
  T.eq("empty string: size kept", cS, SIZE)

  local d, dS = UIHelper.fitText(nil, SIZE, 1.0)
  T.eq("nil text: becomes empty rather than erroring", d, "")
  T.eq("nil text: size kept", dS, SIZE)

  local e, eS = UIHelper.fitText("Soil", 0, 1.0)
  T.eq("zero text size: text untouched", e, "Soil")
  T.eq("zero text size: size returned unchanged", eS, 0)
end

-- ── renderTextFitted draws the fitted string at the fitted size ──
do
  _G.__lastRender = nil
  local used = UIHelper.renderTextFitted(0.1, 0.2, SIZE, "Bodenfeuchtigkeit", 1.6)
  T.ok("renderTextFitted: actually renders", _G.__lastRender ~= nil)
  T.eq("renderTextFitted: renders at the size it reports", _G.__lastRender.size, used)
  T.eq("renderTextFitted: x passed through", _G.__lastRender.x, 0.1)
  T.eq("renderTextFitted: y passed through", _G.__lastRender.y, 0.2)
  T.ok("renderTextFitted: overflowing label was shrunk first", used < SIZE)

  _G.__lastRender = nil
  UIHelper.renderTextFitted(0.1, 0.2, SIZE, "Soil", nil)
  T.eq("renderTextFitted: no width behaves like renderText (size)", _G.__lastRender.size, SIZE)
  T.eq("renderTextFitted: no width behaves like renderText (text)", _G.__lastRender.text, "Soil")
end

-- ── the 26 language point ────────────────────────────────────
-- Same box, longer translations. English fits at full size, the others shrink.
-- None of them may overflow, which is the actual bug reported in #771.
do
  local BOX = 1.8
  for _, label in ipairs({
    "Moisture",              -- en
    "Bodenfeuchtigkeit",     -- de
    "Maaperan kosteus",      -- fi
    "Talajnedvesseg merese", -- hu
    "Vlazhnost pochvy",      -- ru, transliterated to keep this file ascii
  }) do
    local out, size = UIHelper.fitText(label, SIZE, BOX)
    T.ok("'" .. label .. "' stays inside the box", widthOf(out, size) <= BOX + 1e-9)
    T.ok("'" .. label .. "' stays readable, at or above the floor", size >= FLOOR - 1e-9)
  end
end
