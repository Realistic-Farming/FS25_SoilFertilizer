-- SF-771-soilhud_text_fitting_test.lua
--
-- #771: a long translation made the Soil HUD's text run into its neighbour and past the panel
-- edge, because every text on the panel was a raw renderText with no width. The shared helper
-- UIHelper.fitText (shrink to a floor, then an ellipsis, as the game's own text elements do)
-- was already wired into the settings panel; this change draws every translated run on the
-- HUD monitor and on the sprayer rate panel through SoilHUD.drawFitted, which gives each run
-- the width it has. Where a left and a right text share a row, the right one is fitted first
-- (at most 45% of the row) and the left one gets what is left.
--
-- WHERE THE BAR STARTS. The real SoilFertilitySystem builds the field record and field info,
-- the real SoilHUD:update() formats them, and the real SoilHUD:drawPanel() draws them. The
-- fixture supplies the world only: the player in a sprayer, the settings, and the translated
-- text, which is the shipped English text with a prefix of a chosen length put in front of
-- every string (so format specifiers survive and the strings get longer the way a German or
-- Polish translation does). Text measuring is the linear model the settings-panel bench uses
-- (width = size * 0.3 * characters); every drawn run is recorded with the alignment it was
-- drawn with, and the bar reads the extent it covers.
--
-- Groups:
--   U  SoilHUD.drawFitted on its own: a run that fits is drawn exactly as renderText would, a
--      wide one is drawn smaller, past the floor it is cut with an ellipsis, a missing helper or
--      a missing getTextWidth leaves the plain draw, and the width drawn is returned
--   E  English text on the real panel: nothing is cut, every run is drawn at one of the
--      panel's own sizes (a run that fits is not touched)
--   M  a mildly long translation: every run stays inside the panel's inner edges, no two runs
--      on one row overlap, no run is drawn below the shared floor
--   H  a very long translation: the same, and the cut text ends with the ellipsis
--   S  the same at another panel scale and font size, and with a narrowed panel width
--   C  the colour and the bold state each run is drawn with: the right-hand text is now drawn
--      first on the title, field, N/P/K and pH rows, so each row puts the state back for the next draw
--   P  the weed / disease pressure rows (label, "(protected)", the unscouted text)
--   A  a field put to sleep: the one explanatory line, centred, stays inside the panel
--   R  the sprayer rate panel's header, target line and burn warnings, each driven through the
--      real rate manager (auto mode, a rate that may burn, a rate that always burns)
--
-- What this bar does NOT prove: real glyph widths (the model is linear) and the look of the
-- panel on screen. The TESTING row names the in-game check.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SprayerRateManager.lua, src/target/TargetNutrientCore.lua, src/target/TargetFootprint.lua, src/target/TargetApplication.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/utils/UIHelper.lua, src/ui/SoilHUD.lua
--!text: translations/translation_en.xml

SoilLogger.debug = function() end
SoilLogger.info = function() end
SoilLogger.warning = function() end

local function group(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.ok(name .. " ran to its end without a Lua error (" .. tostring(err) .. ")", false) end
end

-- ── the shipped English texts ───────────────────────────────────────
local function unescape(v)
  return (v:gsub("&quot;", '"'):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"))
end
local EN = {}
for k, v in (SOURCE_TEXT["translations/translation_en.xml"] or ""):gmatch('<e%s+k="([^"]+)"%s+v="([^"]*)"') do
  EN[k] = unescape(v)
end
local PREFIX_UNIT = "Uberlangerwortbestandteil-"   -- 26 characters
local curPrefixCount = 0
local function setTexts(prefixCount)
  curPrefixCount = prefixCount
  local prefix = string.rep(PREFIX_UNIT, prefixCount)
  g_i18n = { texts = {}, hasText = function(_, k) return EN[k] ~= nil end,
             getText = function(_, k) return prefix .. (EN[k] or ("Missing '" .. tostring(k) .. "'")) end }
end

-- ── the text model: width = size * 0.3 * characters ─────────────────
local W_PER = 0.3
-- Bold text is wider (the engine measures with the CURRENT bold state), so a run measured
-- before bold is set is measured too narrow and then drawn wider than its room.
local BOLD_FACTOR = 1.15
local boldNow = false
local function widthOf(size, text) return size * W_PER * #tostring(text) * (boldNow and BOLD_FACTOR or 1) end
_G.Utils = _G.Utils or {}
_G.Utils.limitTextToWidth = function(text, size, width, _trimFront, mark)
  local per = size * W_PER * (boldNow and BOLD_FACTOR or 1)
  if per <= 0 then return text end
  local room = math.floor(width / per) - #mark
  if room < 0 then room = 0 end
  if room >= #text then return text end
  return string.sub(text, 1, room) .. mark
end
RenderText = RenderText or { ALIGN_LEFT = 0, ALIGN_CENTER = 1, ALIGN_RIGHT = 2 }

--- Runs fn with the text functions stubbed; every renderText is recorded with the alignment,
--- the colour and the bold state it was drawn with, and the width it was drawn at. Returns the
--- pcall result and the records.
local function recording(fn)
  local drawn, align = {}, RenderText.ALIGN_LEFT
  local color = { 1, 1, 1, 1 }
  boldNow = false
  local saved = { renderText, setTextAlignment, setTextColor, setTextBold, getTextWidth }
  renderText = function(x, y, size, t)
    local w = widthOf(size, t)
    local left, right
    if align == RenderText.ALIGN_RIGHT then left, right = x - w, x
    elseif align == RenderText.ALIGN_CENTER then left, right = x - w / 2, x + w / 2
    else left, right = x, x + w end
    drawn[#drawn + 1] = { x = x, y = y, size = size, text = t, left = left, right = right, w = w,
                          bold = boldNow, color = color }
  end
  setTextAlignment = function(a) align = a end
  setTextColor = function(r, g, b, a) color = { r, g, b, a == nil and 1 or a } end
  setTextBold = function(b) boldNow = (b == true) end
  getTextWidth = widthOf
  local ok, err = pcall(fn)
  boldNow = false
  renderText, setTextAlignment, setTextColor, setTextBold, getTextWidth = saved[1], saved[2], saved[3], saved[4], saved[5]
  return ok, err, drawn
end

-- ── the world: the player in a sprayer with UREA, one field ──────────
local UREA = { name = "UREA", index = 50, massPerLiter = 0.00077 }
FillType = FillType or { UNKNOWN = 0 }
g_fillTypeManager = { getFillTypeByIndex = function(_, i) if i == 50 then return UREA end end,
                      getFillTypeByName  = function(_, n) if n == "UREA" then return UREA end end }
g_sprayTypeManager = { getSprayTypeByFillTypeIndex = function() return nil end }

local FIELD_ID = 7
local function newSprayer()
  local v = { id = 4242, isServer = true, spec_sprayer = { workAreaParameters = { sprayFillType = 50 } } }
  v.rootVehicle = v
  v.getSprayerFillUnitIndex = function() return 1 end
  v.getFillUnitFillType = function() return 50 end
  v.getFillUnitLastValidFillType = function() return 50 end
  v.getFillUnitFillLevel = function() return 500 end
  return v
end

--- The HUD after one frame of its own update(), then the pre-formatted strings a full field
--- would carry (crop, values, the four detail rows) put on it, from the same translated text.
local function frame(opts)
  opts = opts or {}
  g_server = {}
  g_currentMission = { time = 10000 }
  local settings = { enabled = true, autoRateControl = false, replenishmentRate = 3, hudPosition = 1,
                     compactionEnabled = true, weedPressure = true, pestPressure = true, diseasePressure = true,
                     hudFontSize = opts.fontSize, hudTransparency = 3 }
  local ss = setmetatable({ fieldData = {}, settings = settings }, { __index = SoilFertilitySystem })
  local rec = ss:getOrCreateField(FIELD_ID, true, 4.0)
  rec.coverageFraction, rec.sessionCoverageFraction, rec.sessionLastProduct = 0.57, 0.57, "UREA"
  rec.compaction = 40
  ss.targetApplication = TargetApplication.new(ss)
  local rm = SprayerRateManager.new()
  g_SoilFertilityManager = { settings = settings, soilSystem = ss, sprayerRateManager = rm }
  local sprayer = newSprayer()
  g_localPlayer = { getIsInVehicle = function() return true end, getCurrentVehicle = function() return sprayer end }
  local hud = SoilHUD.new(ss, settings)
  hud.fieldDetectTimer = 0
  hud._heightDirty = false
  hud.lastHudPosition = settings.hudPosition
  if opts.scale then hud.scale = opts.scale end
  if opts.widthMult then hud.widthMult = opts.widthMult end
  local info = ss:getFieldInfo(FIELD_ID)
  info.weedPressure, info.herbicideActive = 45, true
  info.pestPressure, info.insecticideActive = 30, false
  info.diseasePressure, info.shownDiseasePressure = 20, nil
  info.yieldEfficiency = 82
  hud.cachedFieldInfo = info
  hud:update(16)
  -- The strings refreshFieldData builds for a field with a crop, from the same translations.
  hud._fmt_fieldText = string.format(g_i18n:getText("sf_hud_field"), FIELD_ID)
  -- the crop is the engine's own display name; a long language gives a long one
  hud._fmt_cropText  = string.rep(PREFIX_UNIT, curPrefixCount) .. "Winter wheat"
  -- The value as drawn is the plain number, then "/target" with a crop target, then the ghost
  -- bar's " (+n)" while a product is loaded; longValues is that longest case.
  if opts.longValues then
    hud._fmt_N, hud._fmt_P, hud._fmt_K = "1234/1500 (+120)", "1234/1500 (+120)", "1234/1500 (+120)"
  else
    hud._fmt_N, hud._fmt_P, hud._fmt_K = "88/110", "42/60", "130/160"
  end
  hud._fmt_omStr = "3.2%"
  hud._fmt_burnText = string.format(g_i18n:getText("sf_hud_amend_burn"), 30)
  hud._fmt_burnRiskText = g_i18n:getText("sf_hud_burn_risk")
  hud._fmt_yieldText = string.format(g_i18n:getText("sf_hud_yield_eff"), 82)
  hud.visible = true
  return hud, info
end

--- The inner edges of the panel and its row pitch.
local function geometry(hud)
  local s = hud.scale
  local pad = SoilHUD.PAD * s
  return { left = hud.panelX + pad, right = hud.panelX + hud:getW() - pad, pad = pad, s = s,
           sameRow = 0.0015 * s }
end

local EPS = 1e-9
local function outside(drawn, g)
  local bad = {}
  for _, t in ipairs(drawn) do
    if t.left < g.left - EPS or t.right > g.right + EPS then
      bad[#bad + 1] = string.format("%q [%.4f..%.4f] inner [%.4f..%.4f]", t.text:sub(1, 36), t.left, t.right, g.left, g.right)
    end
  end
  return bad
end
local function overlaps(drawn, g)
  local bad = {}
  for i = 1, #drawn do
    for j = i + 1, #drawn do
      local a, b = drawn[i], drawn[j]
      if math.abs(a.y - b.y) < g.sameRow and a.left < b.right - EPS and b.left < a.right - EPS then
        bad[#bad + 1] = string.format("%q x %q", a.text:sub(1, 30), b.text:sub(1, 30))
      end
    end
  end
  return bad
end
local function smallest(drawn, nominalSizes, skip)
  -- the smallest ratio of a drawn size to the nearest nominal size at or above it
  local minRatio = 1
  for _, t in ipairs(drawn) do
    if not (skip and skip[t.text]) then
      local best
      for _, n in ipairs(nominalSizes) do
        if n >= t.size - EPS and (best == nil or n < best) then best = n end
      end
      if best and t.size / best < minRatio then minRatio = t.size / best end
    end
  end
  return minRatio
end
local function nominalSizes(hud)
  local fm = SoilConstants.HUD.FONT_SIZE_MULTIPLIERS[hud.settings.hudFontSize or 2]
  local out = {}
  for _, base in ipairs({ 0.012, 0.011, 0.010, 0.009, 0.008, 0.007 }) do out[#out + 1] = base * fm * hud.scale end
  return out
end

local function drawAll(hud) return recording(function() hud:drawPanel() end) end
--- The coverage rows are drawn by drawCoverageLines, which shrinks a wide row in proportion
--- with no floor (#1063); the floor of the shared helper does not apply to them.
local function coverageSet(hud)
  local set = {}
  for _, l in ipairs(hud._fmt_covLines or {}) do set[l] = true end
  return set
end

-- =====================================================================
-- GROUP U: SoilHUD.drawFitted on its own
-- =====================================================================
group("U", function()
  T.ok("U0 the helper exists", type(SoilHUD.drawFitted) == "function")
  local drawn_w
  local ok, err, drawn = recording(function()
    local w = SoilHUD.drawFitted(0.1, 0.2, 0.010, "Soil", 1.0)
    drawn_w = w
  end)
  T.ok("U1 a run that fits is drawn once, at its own size, with its own text",
       ok and #drawn == 1 and drawn[1].size == 0.010 and drawn[1].text == "Soil" and drawn[1].x == 0.1 and drawn[1].y == 0.2)
  T.eq("U2 and the width it took is returned", drawn_w, widthOf(0.010, "Soil"))

  local long = "Bodenfeuchtigkeitsmessung"
  local _, _, d2 = recording(function() SoilHUD.drawFitted(0, 0, 0.010, long, widthOf(0.010, long) * 0.85) end)
  T.ok("U3 a run a little too wide is drawn smaller, its text whole",
       d2[1] ~= nil and d2[1].text == long and d2[1].size < 0.010 and d2[1].w <= widthOf(0.010, long) * 0.85 + EPS)

  local veryLong = string.rep("A", 60)
  local _, _, d3 = recording(function() SoilHUD.drawFitted(0, 0, 0.010, veryLong, widthOf(0.010, veryLong) * 0.4) end)
  T.ok("U4 a run far too wide stops at the floor and is cut with the ellipsis",
       d3[1] ~= nil and d3[1].size >= 0.010 * UIHelper.TEXT_MIN_SIZE_FACTOR - EPS
       and d3[1].text:sub(-3) == "..." and d3[1].w <= widthOf(0.010, veryLong) * 0.4 + EPS)

  local savedHelper = _G.UIHelper
  _G.UIHelper = nil
  local _, _, d4 = recording(function() SoilHUD.drawFitted(0, 0, 0.010, veryLong, 0.01) end)
  _G.UIHelper = savedHelper
  T.ok("U5 with no UIHelper the run is drawn as renderText would, whole and at full size",
       d4[1] ~= nil and d4[1].text == veryLong and d4[1].size == 0.010)

  local savedTW = getTextWidth
  local plain, plainW = {}, nil
  local sRender, sAlign = renderText, setTextAlignment
  renderText = function(x, y, size, t) plain[#plain + 1] = { size = size, text = t } end
  getTextWidth = nil
  plainW = SoilHUD.drawFitted(0, 0, 0.010, "x", 0.5)
  renderText = sRender
  getTextWidth = savedTW
  T.ok("U6 with no getTextWidth the run still draws at full size and the width is 0",
       plain[1] ~= nil and plain[1].size == 0.010 and plainW == 0)

  local _, _, d5 = recording(function() SoilHUD.drawFitted(0, 0, 0.010, nil, 1.0) end)
  T.ok("U7 a nil text draws as an empty string and does not raise", d5[1] ~= nil and d5[1].text == "")
  local retW
  local _, _, d7 = recording(function() retW = SoilHUD.drawFitted(0, 0, 0.010, long, widthOf(0.010, long) * 0.85) end)
  T.ok("U9 after a shrink the width returned is the width it was drawn at, not the nominal one",
       d7[1] ~= nil and math.abs(retW - d7[1].w) < EPS and retW < widthOf(0.010, long))
  local _, _, d6 = recording(function() SoilHUD.drawFitted(0, 0, 0.010, veryLong, nil) end)
  T.ok("U8 no width given draws exactly as renderText would", d6[1] ~= nil and d6[1].text == veryLong and d6[1].size == 0.010)
end)

-- =====================================================================
-- GROUP E: English on the real panel, nothing is touched
-- =====================================================================
group("E", function()
  setTexts(0)
  local hud = frame()
  local g = geometry(hud)
  local ok, err, drawn = drawAll(hud)
  T.ok("E1 the panel drew (" .. tostring(err) .. ")", ok and #drawn > 10)
  local fm = SoilConstants.HUD.FONT_SIZE_MULTIPLIERS[2]
  local function run(text) for _, t in ipairs(drawn) do if t.text == text then return t end end end
  -- A run that fits its room is not touched: named runs, whole and at their own size.
  local untouched = {
    { "title",       EN.sf_hud_title,        0.012 },
    { "field",       string.format(EN.sf_hud_field, 7), 0.010 },
    { "crop",        "Winter wheat",         0.010 },
    { "N value",     "88/110",               0.010 },
    { "P value",     "42/60",                0.010 },
    { "K value",     "130/160",              0.010 },
    { "OM value",    "3.2%",                 0.010 },
    { "weed label",  EN.sf_hud_weeds,        0.010 },
  }
  for i, u in ipairs(untouched) do
    local t = run(u[2])
    T.ok("E" .. (1 + i) .. " " .. u[1] .. " is drawn whole at its own size",
         t ~= nil and math.abs(t.size - u[3] * fm * hud.scale) < EPS)
  end
  T.eq("E10 no run is drawn below the shared floor", (smallest(drawn, nominalSizes(hud), coverageSet(hud)) >= UIHelper.TEXT_MIN_SIZE_FACTOR - 1e-6), true)
  T.eq("E11 every run is inside the inner edges", table.concat(outside(drawn, g), "; "), "")
  T.eq("E12 no two runs on a row overlap", table.concat(overlaps(drawn, g), "; "), "")
end)

-- =====================================================================
-- GROUP C: the colour and bold state each run is drawn with
-- =====================================================================
local function sameRGB(a, b) return a ~= nil and b ~= nil and math.abs(a[1] - b[1]) < EPS and math.abs(a[2] - b[2]) < EPS and math.abs(a[3] - b[3]) < EPS end
local function sameRGBA(a, b) return sameRGB(a, b) and math.abs((a[4] or 1) - (b[4] or 1)) < EPS end
group("C", function()
  setTexts(0)
  local hud = frame()
  local info = hud.cachedFieldInfo   -- the table the panel draws (update() may have replaced the one frame() built)
  local ok, err, drawn = drawAll(hud)
  T.ok("C0 the panel drew (" .. tostring(err) .. ")", ok and #drawn > 10)
  local function run(text) for _, t in ipairs(drawn) do if t.text == text then return t end end end

  local title = run(EN.sf_hud_title)
  T.ok("C1 the title is bold", title ~= nil and title.bold == true)
  T.ok("C2 and white (put back after the badge's colour)", title ~= nil and sameRGBA(title.color, { 1, 1, 1, 1 }))

  local statusLabel, statusCol = hud:overallStatus(info)
  local badge = run(g_i18n:getText("sf_report_rec_" .. statusLabel:lower()))   -- as the code reads it
  local top = {}
  for _, d in ipairs(drawn) do if #top < 4 then top[#top + 1] = d.text:sub(1, 22) .. (d.bold and "(b)" or "") end end
  T.ok("C3 the status badge (" .. tostring(statusLabel) .. ", first runs: " .. table.concat(top, " | ") .. ") is bold", badge ~= nil and badge.bold == true)
  T.ok("C4 and in its own status colour at full alpha", badge ~= nil and sameRGB(badge.color, statusCol) and math.abs(badge.color[4] - 1.0) < EPS)

  local field = run(string.format(EN.sf_hud_field, 7))
  T.ok("C5 the field text is not bold", field ~= nil and field.bold == false)
  T.ok("C6 and in the label colour (put back after the crop's colour)", field ~= nil and sameRGBA(field.color, SoilHUD.C_LABEL))
  local crop = run("Winter wheat")
  T.ok("C7 the crop name is in the dim colour", crop ~= nil and sameRGBA(crop.color, SoilHUD.C_DIM))

  -- N, P, K and pH: the status text is drawn first at 0.80 alpha, then the value at full alpha.
  local function rowState(tag, valueText, status, rgb)
    local value = run(valueText)
    -- the status words repeat across rows, so take the one on the value's own row
    local st
    for _, d in ipairs(drawn) do
      if d.text == SoilHUD.statusText(status) and value ~= nil and math.abs(d.y - value.y) < 0.0015 * hud.scale then st = d end
    end
    T.ok(tag .. " value: in its status colour at full alpha (put back after the status text's 0.80)",
         value ~= nil and sameRGB(value.color, rgb) and math.abs(value.color[4] - 1.0) < EPS)
    T.ok(tag .. " status text: the same colour at 0.80 alpha",
         st ~= nil and sameRGB(st.color, rgb) and math.abs(st.color[4] - 0.80) < EPS)
    T.ok(tag .. " neither is bold", value ~= nil and st ~= nil and value.bold == false and st.bold == false)
  end
  if info.cropTargets == nil then
    rowState("C8 N", "88/110", info.nitrogen.status, hud:statusColor(info.nitrogen.status))
    rowState("C9 P", "42/60", info.phosphorus.status, hud:statusColor(info.phosphorus.status))
    rowState("C10 K", "130/160", info.potassium.status, hud:statusColor(info.potassium.status))
  else
    T.ok("C8 the fixture's field has no crop targets (the colours above are the plain status colours)", false)
  end
  local ph = info.pH
  local phStatus = (ph == nil) and "Unknown" or ((ph >= 6.5 and ph <= 7.0) and "Good" or ((ph >= 5.5 and ph <= 7.5) and "Fair" or "Poor"))
  rowState("C11 pH", ph ~= nil and string.format("%.1f", ph) or "--", phStatus, ph ~= nil and hud:pHColor(ph) or { 0.5, 0.5, 0.5, 1.0 })
end)

-- =====================================================================
-- GROUPS M, H, S: long translations on the real panel
-- =====================================================================
local function longChecks(tag, prefixCount, opts)
  setTexts(prefixCount)
  opts = opts or {}
  opts.longValues = true
  local hud = frame(opts)
  local g = geometry(hud)
  local ok, err, drawn = drawAll(hud)
  T.ok(tag .. "1 the panel drew (" .. tostring(err) .. ")", ok and #drawn > 10)
  local out = outside(drawn, g)
  T.eq(tag .. "2 every run is inside the inner edges (" .. #out .. " outside)", table.concat(out, "; "), "")
  local ov = overlaps(drawn, g)
  T.eq(tag .. "3 no two runs on a row overlap (" .. #ov .. " overlap)", table.concat(ov, "; "), "")
  T.ok(tag .. "4 no run is drawn below the shared floor",
       smallest(drawn, nominalSizes(hud), coverageSet(hud)) >= UIHelper.TEXT_MIN_SIZE_FACTOR - 1e-6)
  return drawn, hud
end

group("M", function()
  local drawn = longChecks("M", 1)
  -- The title is still on the screen: the run at the inner left edge on the topmost row starts
  -- with the first characters of its own text (it may be shortened, it is not dropped).
  local top
  for _, t in ipairs(drawn) do if top == nil or t.y > top.y then top = t end end
  T.ok("M5 the topmost run is the title, shortened or not, starting with its own text",
       top ~= nil and top.text:sub(1, 10) == string.rep(PREFIX_UNIT, 1):sub(1, 10))
end)
group("H", function()
  local drawn = longChecks("H", 4)
  local cut = 0
  for _, t in ipairs(drawn) do if t.text:sub(-3) == "..." then cut = cut + 1 end end
  T.ok("H5 a very long translation is cut with the ellipsis somewhere (" .. cut .. " runs)", cut >= 1)
end)
group("S", function()
  longChecks("S1", 2, { scale = 1.5, fontSize = 3 })
  longChecks("S2", 2, { scale = 0.8, fontSize = 1 })
  longChecks("S3", 2, { widthMult = SoilHUD.MIN_WIDTH_MULT })   -- the narrowest panel the HUD allows
end)

-- =====================================================================
-- GROUP P: the pressure rows drawn on their own (label, protected tag, the unscouted text)
-- =====================================================================
group("P", function()
  setTexts(2)
  local hud = frame()
  local g = geometry(hud)
  local px, pw, s, fm = hud.panelX, hud:getW(), hud.scale, SoilConstants.HUD.FONT_SIZE_MULTIPLIERS[2]
  local ok, err, drawn = recording(function()
    local cy = 0.5
    cy = hud:drawPressureRow("sf_hud_weeds", 45, true, px, cy, pw, s, fm)
    cy = hud:drawPressureRow("sf_hud_pests", 30, false, px, cy, pw, s, fm)
    cy = hud:drawPressureRow("sf_hud_disease", 0, false, px, cy, pw, s, fm, g_i18n:getText("sf_hud_disease_unknown"))
  end)
  T.ok("P1 the rows drew (" .. tostring(err) .. ")", ok and #drawn >= 6)
  T.eq("P2 every pressure run is inside the inner edges", table.concat(outside(drawn, g), "; "), "")
  T.eq("P3 no two pressure runs on a row overlap", table.concat(overlaps(drawn, g), "; "), "")
end)

-- =====================================================================
-- GROUP A: a field put to sleep
-- =====================================================================
group("A", function()
  for _, n in ipairs({ 0, 1, 4 }) do
    setTexts(n)
    local hud, info = frame()
    info.simDisabled = true
    hud.cachedFieldInfo = info
    local g = geometry(hud)
    local ok, err, drawn = drawAll(hud)
    T.ok("A" .. n .. "a the asleep panel drew (" .. tostring(err) .. ")", ok and #drawn >= 3)
    T.eq("A" .. n .. "b every run is inside the inner edges", table.concat(outside(drawn, g), "; "), "")
    local seen = false
    for _, d in ipairs(drawn) do
      if d.text == g_i18n:getText("sf_hud_asleep") or d.text:sub(-3) == "..." or d.text:find("asleep", 1, true) then seen = true end
    end
    T.ok("A" .. n .. "c the one explanatory line is on the screen", seen)
  end
end)

-- =====================================================================
-- GROUP R: the sprayer rate panel's translated lines
-- =====================================================================
local function stepWhere(pred)
  for i, v in ipairs(SoilConstants.SPRAYER_RATE.STEPS) do if pred(v) then return i end end
end
local RATE_VEH = 4242
--- A frame with the rate panel in one state: "off" (the default step), "auto", "may" (a rate
--- that may burn) or "always" (a rate that burns every time), driven through the real rate manager.
local function rateFrame(prefixCount, kind)
  setTexts(prefixCount)
  local hud = frame()
  local rm = g_SoilFertilityManager.sprayerRateManager
  hud.settings.autoRateControl = true
  hud._cachedSprayer = newSprayer()
  hud._cachedFillType = UREA
  if kind == "auto" then rm:setAutoMode(RATE_VEH, true) end
  if kind == "may" then rm:setIndex(RATE_VEH, stepWhere(function(v) return v > SoilConstants.SPRAYER_RATE.BURN_RISK_THRESHOLD and v < SoilConstants.SPRAYER_RATE.BURN_GUARANTEED_THRESHOLD end)) end
  if kind == "always" then rm:setIndex(RATE_VEH, stepWhere(function(v) return v >= SoilConstants.SPRAYER_RATE.BURN_GUARANTEED_THRESHOLD end)) end
  return hud
end
local function anyRun(drawn, pred)
  for _, d in ipairs(drawn) do if pred(d.text) then return d end end
end

group("R", function()
  -- English first: each state reaches the screen with its own text, so the long-text rows below
  -- are reading the runs they claim to.
  local function english(kind, what, pred)
    local hud = rateFrame(0, kind)
    local ok, err, drawn = recording(function() hud:drawSprayerRatePanel() end)
    T.ok("R0 " .. kind .. ": the rate panel drew (" .. tostring(err) .. ")", ok and #drawn >= 1)
    T.ok("R0 " .. kind .. ": " .. what .. " is on the screen", anyRun(drawn, pred) ~= nil)
    return drawn
  end
  local offDrawn = english("off",    "the AUTO: OFF header", function(x) return x:find("AUTO", 1, true) ~= nil and x:find("OFF", 1, true) ~= nil end)
  local header = anyRun(offDrawn, function(x) return x:find("AUTO", 1, true) ~= nil and x:find("OFF", 1, true) ~= nil end)
  T.ok("R0 the rate panel's header is drawn bold (set before it is measured)", header ~= nil and header.bold == true)
  english("auto",   "the target line", function(x) return x:sub(1, #EN.sf_sprayer_target) == EN.sf_sprayer_target end)
  english("may",    "the burn-possible warning", function(x) return x == EN.sf_sprayer_burn_possible end)
  english("always", "the burn-guaranteed warning", function(x) return x == EN.sf_sprayer_burn_guaranteed end)

  for _, n in ipairs({ 1, 2, 5 }) do
    for _, kind in ipairs({ "off", "auto", "may", "always" }) do
      local hud = rateFrame(n, kind)
      local ok, err, drawn = recording(function() hud:drawSprayerRatePanel() end)
      T.ok("R" .. n .. kind .. "a the rate panel drew (" .. tostring(err) .. ")", ok and #drawn >= 1)
      local pw = hud:getW()
      local worst, wide = 0, nil
      for _, d in ipairs(drawn) do
        if d.w > pw * 0.94 + EPS and d.w > worst then worst, wide = d.w, d.text end
      end
      T.ok("R" .. n .. kind .. "b no run is wider than 94% of the panel (the widest, " .. tostring(wide and wide:sub(1, 24)) .. ", is " .. worst .. ")", wide == nil)
    end
  end
end)
